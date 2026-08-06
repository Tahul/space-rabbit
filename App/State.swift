/*
 * State.swift — Global runtime state and persistence
 *
 * All mutable runtime state lives here as module-level globals.
 * This is intentional: the app is a single-process menu bar utility
 * with no concurrency beyond the main thread, so global state is
 * simpler and more appropriate than a singleton class.
 *
 * Persisted values are backed by UserDefaults under the "spacerabbit." prefix.
 */

import CoreGraphics
import Foundation

// MARK: - Event Tap State

/// The active CGEvent tap (installed at startup, never replaced).
/// Used by the event tap callback to intercept space-switch shortcuts,
/// and re-enabled automatically if macOS disables it.
var gTap: CFMachPort?

// MARK: - Feature Toggles

/// Master on/off toggle.
/// When `false`, both instant-switch and auto-follow are disabled,
/// and the menu bar icon fades to indicate the inactive state.
var gEnabled: Bool = true

/// Feature 1 toggle: intercept space-switch hotkeys and post instant gestures.
/// Only effective when `gEnabled` is also `true`.
var gInstantSwitchEnabled: Bool = true

/// Feature 2 toggle: follow activated apps to their space on Cmd+Tab.
/// Only effective when `gEnabled` is also `true`.
var gAutoFollowEnabled: Bool = true

/// Whether the configurable global cycle shortcut is active.
/// Only effective when `gEnabled` is true and the transition speed is not Normal.
var gCycleShortcutEnabled: Bool = false

/// Space-switch transition speed as a slider tick position (0.0–1.0 in
/// steps of 0.25). 1.0 (the end cap) means instant — no animation at all.
/// 0.0 ("Normal") means macOS's native animation: Space Rabbit posts no
/// gestures and lets the OS switch on its own (see `isNativeSwitchSpeed()`).
/// The ticks in between post gestures at increasing animated velocities
/// (see `currentSwitchVelocity()`).
var gSwitchSpeed: Double = 1.0

// MARK: - Space Switch Timing

/// Timestamp of the last space switch triggered by instant-switch.
///
/// Used to suppress auto-follow immediately after an instant-switch,
/// preventing the two features from fighting each other. Without this
/// guard, instant-switch would change spaces and then auto-follow would
/// see the resulting app-activation notification and chase a second
/// window on yet another space.
var gLastSpaceSwitchTime: Date = .distantPast

// MARK: - Statistics

/// Lifetime count of space switches performed by Space Rabbit.
/// Incremented by both instant-switch and auto-follow.
/// Persisted to UserDefaults periodically (every 5 minutes) and on exit.
var gSwitchCount: Int = 0

/// The last value of `gSwitchCount` that was written to disk.
/// Compared against `gSwitchCount` to avoid unnecessary UserDefaults writes.
var gSwitchCountSaved: Int = 0

// MARK: - Keyboard Shortcut State
//
// These hold the user's configured space-switch shortcuts, loaded from
// macOS system preferences (see Shortcuts.swift). The event tap compares
// incoming key events against these values. A `nil` binding means the
// hotkey is disabled in System Settings — nothing is intercepted for it.

/// A keyboard shortcut: virtual keycode plus its exact modifier set.
typealias KeyBinding = (keycode: Int64, mods: CGEventFlags)

/// Virtual keycode emitted by the Fn/Globe key on Apple keyboards.
let kFnKeycode: Int64 = 63

/// Modifiers checked when matching ordinary configurable cycle shortcuts.
/// Fn is included to reject it as an unrecorded extra modifier. The automatic
/// function flag on special/F-keys is normalized separately.
let kCycleShortcutModifiers: CGEventFlags = [
    .maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn
]

/// State of a possible bare-Fn press while waiting for its release.
enum BareFnPressState {
    case idle
    case candidate
    case chorded

    var isDown: Bool {
        if case .idle = self { return false }
        return true
    }

    mutating func begin(usedAsModifier: Bool) {
        guard case .idle = self else { return }
        self = usedAsModifier ? .chorded : .candidate
    }

    mutating func markChorded() {
        guard isDown else { return }
        self = .chorded
    }

    /// Finishes the press and returns whether it remained a bare-Fn tap.
    mutating func finish() -> Bool {
        let wasBare: Bool
        if case .candidate = self { wasBare = true } else { wasBare = false }
        self = .idle
        return wasBare
    }

    mutating func reset() {
        self = .idle
    }
}

/// A persisted global shortcut for cycling to the next Space.
struct CycleShortcut {
    /// F-key virtual keycodes and their recorder labels.
    static let functionKeyLabels: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Non-F keys whose events carry `.maskSecondaryFn` automatically even
    /// when the physical Fn key is not held. AppKit classifies these as
    /// function/navigation keys, so that synthesized flag must be ignored
    /// during modifier matching.
    private static let implicitFunctionFlagKeycodes: Set<Int64> = [
        71,                          // Keypad Clear
        114,                         // Help / Insert
        115, 116, 117, 119, 121,    // Home, Page Up, Forward Delete, End, Page Down
        123, 124, 125, 126,         // Arrow keys
    ]

    let keycode: Int64
    let modifiers: CGEventFlags
    let keyLabel: String

    /// Default shortcut used when the feature has not been configured.
    static let fn = CycleShortcut(keycode: kFnKeycode, modifiers: [], keyLabel: "fn")

    /// Whether this binding represents a tap of Fn/Globe by itself.
    var isBareFn: Bool { keycode == kFnKeycode && modifiers.isEmpty }

    /// Whether the primary key is F1 through F20.
    var isFunctionKey: Bool { Self.functionKeyLabels[keycode] != nil }

    /// Whether modifier matching should normalize away the function flag.
    /// Navigation keys carry it implicitly; F-keys ignore it so both macOS
    /// top-row modes resolve to the same binding.
    var normalizesFunctionFlag: Bool {
        isFunctionKey || Self.implicitFunctionFlagKeycodes.contains(keycode)
    }

    /// Modifier flags considered when matching this shortcut.
    var matchingModifierMask: CGEventFlags {
        normalizesFunctionFlag
            ? kCycleShortcutModifiers.subtracting(.maskSecondaryFn)
            : kCycleShortcutModifiers
    }

    /// Compact macOS-style glyph string shown by the recorder control.
    var displayString: String {
        if isBareFn { return keyLabel }

        var result = ""
        if modifiers.contains(.maskControl)     { result += "⌃" }
        if modifiers.contains(.maskAlternate)   { result += "⌥" }
        if modifiers.contains(.maskShift)       { result += "⇧" }
        if modifiers.contains(.maskCommand)     { result += "⌘" }
        return result + keyLabel
    }
}

/// Configured cycle binding. Defaults to Fn while the feature remains off.
/// `nil` means the user explicitly cleared the recorder.
var gCycleShortcut: CycleShortcut? = .fn

/// True while the Preferences shortcut field is recording. The global event
/// tap passes keyboard events through so the field can receive them locally.
var gIsRecordingCycleShortcut = false

/// Binding for "move left a space" (default: Control + Left Arrow).
/// `nil` when the hotkey is disabled in System Settings.
var gBindingLeft: KeyBinding? = (keycode: 123, mods: .maskControl)

/// Binding for "move right a space" (default: Control + Right Arrow).
/// `nil` when the hotkey is disabled in System Settings.
/// Left and right are independent — they may carry different modifiers.
var gBindingRight: KeyBinding? = (keycode: 124, mods: .maskControl)

/// Per-desktop "Switch to Desktop N" bindings (index 0 = Desktop 1 ... index 9 = Desktop 10).
/// `nil` means the slot is not bound or disabled in System Settings.
var gSpaceKeys: [KeyBinding?] = Array(repeating: nil, count: 10)

// MARK: - UI References

/// The menu bar status item instance (created at startup in `main.swift`).
var gMenu: SwoopMenu?

// MARK: - UserDefaults Keys

/// Centralizes all UserDefaults key strings to avoid typos and make
/// them discoverable in one place.
///
/// All keys use the `"spacerabbit."` prefix to namespace them within
/// the app's UserDefaults domain.
enum Defaults {
    static let enabled         = "spacerabbit.enabled"
    static let instantSwitch   = "spacerabbit.instantSwitch"
    static let autoFollow      = "spacerabbit.autoFollow"
    static let cycleShortcutEnabled   = "spacerabbit.cycleShortcut.enabled"
    static let cycleShortcutKeycode   = "spacerabbit.cycleShortcut.keycode"
    static let cycleShortcutModifiers = "spacerabbit.cycleShortcut.modifiers"
    static let cycleShortcutLabel     = "spacerabbit.cycleShortcut.label"
    static let switchSpeed     = "spacerabbit.switchSpeed"
    static let switchCount     = "spacerabbit.switchCount"
    /// When `false`, the rabbit icon is removed from the menu bar.
    /// Preferences remain reachable by launching Space Rabbit again.
    static let showMenuBarIcon = "spacerabbit.showMenuBarIcon"
}

// MARK: - Persistence

/// Writes the configurable cycle shortcut and its enabled state.
func persistCycleShortcut() {
    let defaults = UserDefaults.standard
    defaults.set(gCycleShortcutEnabled, forKey: Defaults.cycleShortcutEnabled)

    if let shortcut = gCycleShortcut {
        defaults.set(shortcut.keycode, forKey: Defaults.cycleShortcutKeycode)
        defaults.set(shortcut.modifiers.rawValue,
                     forKey: Defaults.cycleShortcutModifiers)
        defaults.set(shortcut.keyLabel, forKey: Defaults.cycleShortcutLabel)
    } else {
        // A negative keycode distinguishes an explicitly-cleared recorder
        // from a fresh install, whose latent default remains Fn.
        defaults.set(-1, forKey: Defaults.cycleShortcutKeycode)
        defaults.removeObject(forKey: Defaults.cycleShortcutModifiers)
        defaults.removeObject(forKey: Defaults.cycleShortcutLabel)
    }
}

/// Writes the current switch count to UserDefaults if it has changed.
///
/// Called periodically (every 5 minutes) and on app termination.
/// This batching approach reduces disk I/O compared to writing on every
/// single switch — at the cost of potentially losing a few counts if
/// the app crashes (acceptable trade-off for a utility app).
func flushSwitchCount() {
    guard gSwitchCount != gSwitchCountSaved else { return }
    UserDefaults.standard.set(gSwitchCount, forKey: Defaults.switchCount)
    gSwitchCountSaved = gSwitchCount
}
