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

/// Whether to play a sound effect when toggling the master switch via right-click.
var gSoundsEnabled: Bool = false

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
// These hold the user's configured "Move left/right a space" shortcuts,
// loaded from macOS system preferences at startup (see Shortcuts.swift).
// The event tap compares incoming key events against these values.

/// Virtual keycode for "move left a space" (default: 123 = left arrow).
var gKeyLeft: Int64 = 123

/// Virtual keycode for "move right a space" (default: 124 = right arrow).
var gKeyRight: Int64 = 124

/// Required modifier flags for the space-switch shortcut (default: Control).
/// Both left and right shortcuts share the same modifier mask.
var gModMask: CGEventFlags = .maskControl

/// Per-desktop "Switch to Desktop N" bindings (index 0 = Desktop 1 ... index 9 = Desktop 10).
/// `nil` means the slot is not bound or disabled in System Settings.
var gSpaceKeys: [(keycode: Int64, mods: CGEventFlags)?] = Array(repeating: nil, count: 10)

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
    static let enabled       = "spacerabbit.enabled"
    static let instantSwitch = "spacerabbit.instantSwitch"
    static let autoFollow    = "spacerabbit.autoFollow"
    static let sounds        = "spacerabbit.sounds"
    static let switchCount   = "spacerabbit.switchCount"
}

// MARK: - Persistence

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
