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
 * We read these at startup so the event tap knows which key
 * combination to intercept. If the shortcuts are disabled or
 * unreadable, we fall back to Control + Arrow Keys.
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

// MARK: - Hotkey Parsing

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
/// (the user cleared the shortcut).
///
/// - Parameters:
///   - hotkeys: The `AppleSymbolicHotKeys` dictionary from system preferences.
///   - key: The hotkey ID string (e.g. "79" or "81").
///   - keycode: Updated with the parsed virtual keycode (if valid).
///   - mods: Updated with the parsed modifier flags (if valid).
private func readHotkey(from hotkeys: NSDictionary, key: String,
                        keycode: inout Int64, mods: inout CGEventFlags) {
    guard let entry = hotkeys[key] as? NSDictionary else { return }

    // Check if the hotkey is enabled (skip disabled entries)
    if let enabled = entry["enabled"] {
        if let flag   = enabled as? Bool,                       !flag     { return }
        if let number = (enabled as? NSNumber)?.intValue, number == 0    { return }
    }

    guard let value  = entry["value"]      as? NSDictionary,
          let params = value["parameters"] as? NSArray,
          params.count >= 3 else { return }

    let newKeycode = (params[1] as? NSNumber)?.int64Value ?? 0
    let newMods    = (params[2] as? NSNumber)?.int64Value ?? 0

    // 65535 means the keycode slot is empty (user cleared the shortcut)
    if newKeycode != 65535 { keycode = newKeycode }

    // 0 means no modifiers are set — keep the existing default
    if newMods != 0 { mods = carbonToCGFlags(newMods) }
}

// MARK: - Public Interface

/// Reads the user's configured "Move left/right a space" shortcuts
/// from macOS system preferences and updates the global state
/// (`gKeyLeft`, `gKeyRight`, `gModMask`).
///
/// Falls back to the defaults (Control + Arrow Keys) if the preferences
/// cannot be read or the hotkeys are disabled.
///
/// Called once at startup from `main.swift`.
func loadSpaceSwitchShortcuts() {
    guard let prefs = CFPreferencesCopyAppValue(
        "AppleSymbolicHotKeys" as CFString,
        "com.apple.symbolichotkeys" as CFString
    ) as? NSDictionary else { return }

    var leftMods  = CGEventFlags()
    var rightMods = CGEventFlags()

    readHotkey(from: prefs, key: kHotkeyMoveLeftSpace,  keycode: &gKeyLeft,  mods: &leftMods)
    readHotkey(from: prefs, key: kHotkeyMoveRightSpace, keycode: &gKeyRight, mods: &rightMods)

    // Use whichever modifier set is non-empty. Both sides should have the
    // same modifiers, but if only one side is configured, prefer that one.
    if      !leftMods.isEmpty  { gModMask = leftMods  }
    else if !rightMods.isEmpty { gModMask = rightMods }

    // Hotkeys 118..127 = "Switch to Desktop 1".."Switch to Desktop 10"
    for i in 0..<10 {
        var keycode: Int64        = -1
        var mods:    CGEventFlags = []
        readHotkey(from: prefs, key: String(118 + i), keycode: &keycode, mods: &mods)
        // Require at least one modifier to avoid intercepting bare number keys
        if keycode != -1, !mods.isEmpty {
            gSpaceKeys[i] = (keycode, mods)
        }
    }
}
