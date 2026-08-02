/*
 * Shortcuts.swift — System keyboard shortcut reading
 *
 * macOS stores the user's configured keyboard shortcuts for
 * "Move left/right a space" in the com.apple.symbolichotkeys
 * preference domain. The hotkey IDs are:
 *
 *   79 = Move left a space
 *   81 = Move right a space
 *
 * We read these at startup (and re-read them when System Settings
 * deactivates — see main.swift) so the event tap knows which key
 * combinations to intercept. Absent or unreadable entries fall back to
 * the macOS defaults (Control + Arrow Keys); hotkeys the user disabled
 * are not intercepted at all.
 */

import CoreGraphics
import CoreFoundation
import Foundation

// MARK: - Hotkey IDs

/// Symbolic hotkey ID for "Move left a space" in System Settings.
private let kHotkeyMoveLeftSpace  = "79"

/// Symbolic hotkey ID for "Move right a space" in System Settings.
private let kHotkeyMoveRightSpace = "81"

// MARK: - Carbon Modifier Flags
//
// macOS system preferences store modifier keys using the legacy Carbon
// bitmask format. These constants map each Carbon bit to its meaning.

/// Carbon modifier bitmask values (from the HIToolbox framework era).
/// Used to decode the modifier flags stored in symbolic hotkey entries.
private enum CarbonModifier {
    static let shift:   Int64 = 0x020000
    static let control: Int64 = 0x040000
    static let option:  Int64 = 0x080000
    static let command: Int64 = 0x100000
}

/// Converts Carbon-era modifier flags (as stored in symbolic hotkeys)
/// to their CoreGraphics equivalents.
///
/// - Parameter carbon: The raw Carbon modifier bitmask.
/// - Returns: The equivalent `CGEventFlags` value.
private func carbonToCGFlags(_ carbon: Int64) -> CGEventFlags {
    var flags = CGEventFlags()
    if carbon & CarbonModifier.control != 0 { flags.insert(.maskControl)   }
    if carbon & CarbonModifier.shift   != 0 { flags.insert(.maskShift)     }
    if carbon & CarbonModifier.option  != 0 { flags.insert(.maskAlternate) }
    if carbon & CarbonModifier.command != 0 { flags.insert(.maskCommand)   }
    return flags
}

// MARK: - Default Bindings

/// Built-in macOS default bindings, applied when a symbolic-hotkey entry
/// is absent from the preferences (the system falls back to these too).
private let kDefaultBindingLeft:  KeyBinding = (keycode: 123, mods: .maskControl)
private let kDefaultBindingRight: KeyBinding = (keycode: 124, mods: .maskControl)

// MARK: - Hotkey Parsing

/// Parse result for one symbolic-hotkey entry.
private enum HotkeyState {
    /// No usable entry — macOS applies its built-in default binding.
    case systemDefault
    /// Present but switched off, or its keycode slot cleared: the shortcut
    /// does nothing natively, so Space Rabbit must not intercept it either.
    case disabled
    /// Present and enabled with an explicit binding.
    case bound(KeyBinding)
}

/// Reads a single hotkey entry from the symbolic hotkeys dictionary.
///
/// Each entry is structured as:
/// ```
/// "79" = {
///     enabled = 1;
///     value = {
///         parameters = (65535, 123, 8650752);
///         type = "standard";
///     };
/// };
/// ```
///
/// Where `parameters[1]` is the virtual keycode and `parameters[2]`
/// is the Carbon modifier flags. A keycode of `65535` means "not set"
/// (the user cleared the shortcut). Entries may also carry no (or
/// malformed) parameters — e.g. enabled-only entries that keep the
/// built-in default binding — which reads as `.systemDefault`.
///
/// - Parameters:
///   - hotkeys: The `AppleSymbolicHotKeys` dictionary from system preferences.
///   - key: The hotkey ID string (e.g. "79" or "81").
/// - Returns: See `HotkeyState`.
private func readHotkey(from hotkeys: NSDictionary, key: String) -> HotkeyState {
    guard let entry = hotkeys[key] as? NSDictionary else { return .systemDefault }

    // Switched off in System Settings
    if let enabled = entry["enabled"] {
        if let flag   = enabled as? Bool,                    !flag        { return .disabled }
        if let number = (enabled as? NSNumber)?.intValue, number == 0 { return .disabled }
    }

    guard let value   = entry["value"]      as? NSDictionary,
          let params  = value["parameters"] as? NSArray,
          params.count >= 3,
          let keycode = (params[1] as? NSNumber)?.int64Value,
          let carbon  = (params[2] as? NSNumber)?.int64Value
    else { return .systemDefault }

    // 65535 means the keycode slot is empty (user cleared the shortcut)
    guard keycode != 65535, keycode >= 0 else { return .disabled }

    return .bound((keycode: keycode, mods: carbonToCGFlags(carbon)))
}

// MARK: - Public Interface

/// Reads the user's configured space-switch shortcuts from macOS system
/// preferences and updates the global bindings (`gBindingLeft`,
/// `gBindingRight`, `gSpaceKeys`).
///
/// Every global is reset on each call, so this can also *reload* after
/// the user edits shortcuts in System Settings: disabled hotkeys become
/// `nil` (nothing intercepted), absent entries fall back to the macOS
/// defaults (Control + Arrow Keys), and left/right may carry different
/// modifiers.
///
/// Called at startup and whenever System Settings deactivates (main.swift).
func loadSpaceSwitchShortcuts() {
    // Pull fresh values first — the domain belongs to another process
    // and may have changed since our last read
    CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)

    guard let prefs = CFPreferencesCopyAppValue(
        "AppleSymbolicHotKeys" as CFString,
        "com.apple.symbolichotkeys" as CFString
    ) as? NSDictionary else {
        gBindingLeft  = kDefaultBindingLeft
        gBindingRight = kDefaultBindingRight
        gSpaceKeys    = Array(repeating: nil, count: 10)
        return
    }

    /// Resolves one hotkey entry to its effective binding.
    func binding(for key: String, default defaultBinding: KeyBinding) -> KeyBinding? {
        switch readHotkey(from: prefs, key: key) {
        case .systemDefault:  return defaultBinding
        case .disabled:       return nil
        case .bound(let b):   return b
        }
    }

    gBindingLeft  = binding(for: kHotkeyMoveLeftSpace,  default: kDefaultBindingLeft)
    gBindingRight = binding(for: kHotkeyMoveRightSpace, default: kDefaultBindingRight)

    // Hotkeys 118..127 = "Switch to Desktop 1".."Switch to Desktop 10".
    // These have no enabled-by-default system binding, and bare number
    // keys must never be intercepted — require at least one modifier.
    for i in 0..<10 {
        if case .bound(let b) = readHotkey(from: prefs, key: String(118 + i)),
           !b.mods.isEmpty {
            gSpaceKeys[i] = b
        } else {
            gSpaceKeys[i] = nil
        }
    }
}
