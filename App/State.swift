/*
 * State.swift — Global runtime state and persistence
 *
 * All mutable runtime state lives here as module-level globals.
 * This is intentional: the app is a single-process menu bar utility, so
 * global state is simpler and more appropriate than a singleton class.
 * State is main-thread-owned unless its declaration documents a dedicated
 * serial queue (the Mission Control animator is the only exception).
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

/// The gesture-intercept CGEvent tap. Unlike `gTap`, this one is created and
/// torn down on demand: it only exists while the master switch and at least
/// one gesture-interception feature are enabled (see `updateSwipeTap()`).
var gSwipeTap: CFMachPort?

/// Run loop source backing `gSwipeTap`, kept so the source can be removed
/// from the run loop when the tap is torn down.
var gSwipeTapSource: CFRunLoopSource?

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

/// Feature 3 toggle: intercept real trackpad swipes and replace
/// them with instant switches. Off by default (opt-in) — it swallows the
/// user's physical gesture, which is a bigger behavioral change than the
/// purely additive features above. Only effective when `gEnabled` is `true`.
var gTrackpadSwipeEnabled: Bool = false

/// Optional Mission Control transition interception. Replaces upward entry and
/// downward dismissal with vertical DockSwipes governed by the shared
/// transition-speed control. Off by default because it swallows physical
/// gestures and relies on private event fields. Independent from Feature 3.
var gInstantMissionControlEnabled: Bool = false

/// Global transition speed as a slider tick position (0.0–1.0 in steps of
/// 0.25), shared by keyboard Space switches, app auto-follow, physical Space
/// swipes, and Mission Control entry/dismissal. 1.0 (the end cap) means
/// instant — no animation at all.
/// 0.0 ("Normal") means macOS's native animation: Space Rabbit posts no
/// gestures and lets the OS switch on its own (see `isNativeSwitchSpeed()`).
/// The ticks in between post progressively faster animated gestures. Horizontal
/// switches use increasing terminal velocities (`currentSwitchVelocity()`),
/// while Mission Control uses equivalent timed progress durations.
var gSwitchSpeed: Double = 1.0

/// Clamps and snaps an externally supplied transition speed to one of the
/// slider's five supported tick values. Corrupt or non-finite preferences use
/// the safe default (Instant) instead of leaking invalid timing values into
/// gesture construction.
func normalizedSwitchSpeed(_ value: Double) -> Double {
    guard value.isFinite else { return 1.0 }
    let clamped = min(max(value, 0), 1)
    return (clamped * 4).rounded() / 4
}

// MARK: - Space Switch Timing

/// Timestamp of the last space switch triggered by instant-switch.
///
/// Used to suppress auto-follow immediately after an instant-switch,
/// preventing the two features from fighting each other. Without this
/// guard, instant-switch would change spaces and then auto-follow would
/// see the resulting app-activation notification and chase a second
/// window on yet another space.
var gLastSpaceSwitchTime: Date = .distantPast

/// Process ID of the app auto-follow last chased to another space, or `-1`
/// when no follow is pending an echo. Cleared as soon as a *different* app
/// activates, so it only ever suppresses back-to-back notifications for the
/// same app — never the user's next Cmd+Tab (issue #24).
var gLastFollowedPid: pid_t = -1

/// Timestamp paired with `gLastFollowedPid`.
var gLastFollowedTime: Date = .distantPast

/// Space ID auto-follow last asked the Dock to move to, or `0` when none is
/// outstanding. The `activeSpaceDidChangeNotification` observer in
/// `main.swift` uses it to recognize the space change it caused itself and
/// skip stamping `gLastSpaceSwitchTime` for it — that notification arrives
/// only once the transition settles, so stamping it would keep auto-follow
/// suppressed for far longer than `kAutoFollowSuppressionWindow` and hand
/// the user's next rapid Cmd+Tab back to macOS's animated switch (issue #24).
var gAutoFollowTargetSpace: CGSSpaceID = 0

// MARK: - Swipe Intercept State
//
// Tracking state for the shared gesture-intercept tap. One physical swipe
// produces a Began → Changed… → Ended/Cancelled event sequence; these
// values carry an unresolved prefix or the decision "we own this gesture"
// across it.
// Reset together via resetSwipeIntercept() in SwipeIntercept.swift.

/// Whether a real trackpad dock swipe is currently being intercepted
/// (its Began phase was swallowed, so we must handle the rest too).
var gSwipeTracking: Bool = false

/// Whether the intercepted swipe already fired its instant switch
/// (fires once per gesture, on the first Changed with non-zero progress).
var gSwipeFired: Bool = false

/// Whether a Mission Control entry/dismissal swipe has been replaced and the
/// rest of its physical event sequence must be swallowed.
var gMissionControlSwipeTracking: Bool = false

/// A vertical gesture prefix held until the first non-zero progress sample
/// identifies the direction. Copied events are replayed through the tap proxy
/// when Space Rabbit does not claim the gesture.
var gPendingMissionControlEvents: [CGEvent] = []

/// Exact overview state captured with the pending vertical Began. The live
/// state may already be transitioning by the time Changed reveals direction.
var gPendingMissionControlOverviewState: DockOverviewState?

// MARK: - Mission Control Animation State

/// A fully constructed terminal pair retained before an animated gesture
/// begins. If constructing a later sample fails, posting this pair guarantees
/// that the Dock never receives an unterminated synthetic gesture.
struct MissionControlTerminalEvents {
    let changed: CGEvent
    let ended: CGEvent
}

/// Queue-owned state for the one Mission Control animation that may be active.
/// The fallback terminal pair is also used when a newer physical gesture
/// interrupts this animation.
struct MissionControlAnimationState {
    let id: UInt64
    let direction: Int
    let augmented: Bool
    let fallbackTerminal: MissionControlTerminalEvents
}

/// These two globals are accessed only on
/// `kMissionControlAnimationQueue` in SpaceSwitching.swift. Keeping them here
/// preserves the repository's single state-module convention while making the
/// queue-ownership exception explicit.
var gMissionControlAnimation: MissionControlAnimationState?
var gMissionControlAnimationID: UInt64 = 0

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
    static let enabled          = "spacerabbit.enabled"
    static let instantSwitch    = "spacerabbit.instantSwitch"
    static let autoFollow       = "spacerabbit.autoFollow"
    /// The stored key keeps its original `threeFingerSwipe` spelling on
    /// purpose — the feature was renamed to "Instant Trackpad Swipe", and
    /// renaming the key would silently reset the opt-in for existing users.
    static let trackpadSwipe    = "spacerabbit.threeFingerSwipe"
    static let instantMissionControl = "spacerabbit.instantMissionControl"
    static let switchSpeed      = "spacerabbit.switchSpeed"
    static let switchCount      = "spacerabbit.switchCount"
    /// When `false`, the rabbit icon is removed from the menu bar.
    /// Preferences remain reachable by launching Space Rabbit again.
    static let showMenuBarIcon  = "spacerabbit.showMenuBarIcon"
    /// `Date.timeIntervalSinceReferenceDate` of the last update check
    /// (automatic or manual), used to throttle the launch-time check.
    static let lastUpdateCheck  = "spacerabbit.lastUpdateCheck"
    /// Release tag of the newer version found by the last check, and the DMG
    /// URL to install it. Kept so the update banner survives a relaunch that
    /// is throttled out of checking again. Cleared once the check reports the
    /// running version is up to date.
    static let pendingUpdateVersion = "spacerabbit.pendingUpdateVersion"
    static let pendingUpdateURL     = "spacerabbit.pendingUpdateURL"
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
