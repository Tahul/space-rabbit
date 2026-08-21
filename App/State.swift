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

/// The active CGEvent tap (installed at startup via `installEventTap()`).
/// Used by the event tap callback to intercept space-switch shortcuts,
/// and re-enabled automatically if macOS disables it. Rebuilt by
/// `reviveKeyboardTapsIfNeeded()` when its Mach port dies across system
/// sleep or screen lock.
///
/// It listens for `keyDown` only — the sole event form that can *match* a
/// shortcut. The other three keyboard event forms the feature needs are split
/// onto the two on-demand taps below, for the reason described at
/// `gGestureEnvelopeTap`: every subscribed event costs a synchronous
/// round-trip through this process, so a type that is only meaningful in a
/// narrow window should not be subscribed to outside it. Measured while
/// typing on macOS 26: `keyUp` is exactly as frequent as `keyDown`, and was
/// half of this tap's wakeups.
var gTap: CFMachPort?

/// Run loop source backing `gTap`, kept so the source can be removed when
/// the tap is rebuilt after wake (and on termination).
var gTapSource: CFRunLoopSource?

/// Tap for `keyUp` and `systemDefined`, enabled only while a key press has
/// actually been claimed or a bare-Fn candidate is in progress
/// (`syncKeyboardAuxiliaryTaps()`).
///
/// Both types exist purely to close out a press that already matched: the
/// release paired with a swallowed key-down, and the media keys that cancel a
/// bare-Fn candidate. Neither can ever *start* anything, so outside that
/// window they are dead weight on every keystroke.
var gClaimedKeyTap: CFMachPort?

/// Run loop source backing `gClaimedKeyTap`.
var gClaimedKeyTapSource: CFRunLoopSource?

/// Whether `gClaimedKeyTap` is currently enabled.
var gClaimedKeyTapEnabled: Bool = false

/// Tap for `flagsChanged`, enabled only while a cycle shortcut is configured
/// and the recorder is not running.
///
/// Modifier transitions are observed exclusively to track physical Fn for the
/// configurable cycle shortcut. With no shortcut recorded — the default — the
/// callback passes every one of them straight back, so the tap is simply not
/// installed instead.
var gModifierKeyTap: CFMachPort?

/// Run loop source backing `gModifierKeyTap`.
var gModifierKeyTapSource: CFRunLoopSource?

/// Whether `gModifierKeyTap` is currently enabled.
var gModifierKeyTapEnabled: Bool = false

/// The gesture-intercept CGEvent tap. Unlike `gTap`, this one is created and
/// torn down on demand: it only exists while the master switch and at least
/// one gesture-interception feature are enabled (see `updateSwipeTap()`).
///
/// It listens for `kCGSEventDockControl` only — the low-rate event type that
/// actually carries a DockSwipe. The generic envelopes that accompany them
/// have their own tap, below.
var gSwipeTap: CFMachPort?

/// Run loop source backing `gSwipeTap`, kept so the source can be removed
/// from the run loop when the tap is torn down.
var gSwipeTapSource: CFRunLoopSource?

/// Companion tap for the generic `kCGSEventGesture` envelopes, created and
/// destroyed alongside `gSwipeTap` but kept *disabled* unless a gesture is
/// actually claimed (see `syncGestureEnvelopeTap()`).
///
/// Those envelopes are emitted for any finger resting on or moving across the
/// trackpad — roughly 20-60 per second of ordinary cursor movement, versus a
/// handful of DockControl events in the same span. A `.defaultTap` is a
/// synchronous IPC round-trip, so subscribing to them full-time woke the
/// process on every touch sample for events it only ever needs while a swipe
/// is in progress.
var gGestureEnvelopeTap: CFMachPort?

/// Run loop source backing `gGestureEnvelopeTap`.
var gGestureEnvelopeTapSource: CFRunLoopSource?

/// Whether `gGestureEnvelopeTap` is currently enabled, so the state is only
/// pushed to the window server when it actually changes.
var gGestureEnvelopeTapEnabled: Bool = false

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

/// Timestamp of the last key-down matching the auto-follow ignore list
/// (`gAutoFollowIgnoredChords`), or `.distantPast`.
///
/// Auto-follow stands down for the app activation that follows one of the
/// listed hotkeys: the hotkey's app is about to open a popup on the
/// *current* space, and the popup window does not exist yet when the
/// activation notification arrives — chasing the app's other windows
/// would yank the user away from the popup they just summoned. Stamped
/// by the keyboard event tap (EventTap.swift), read by `SwoopObserver`
/// (AutoFollow.swift).
var gLastHotkeyChordTime: Date = .distantPast

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

/// Direction the intercepted horizontal swipe has most recently acted on
/// (`+1` right, `-1` left, `0` while the gesture has carried no trusted
/// direction yet). A non-zero value both stands in for "already fired" and
/// says which way, so a reversal of the same physical gesture can undo it.
var gSwipeIntentDirection: Int = 0

/// Furthest `kCGEventGestureSwipeProgress` reached in `gSwipeIntentDirection`
/// since it was last acted on. Reversal is measured as travel back from this
/// extreme, not from the touchdown origin, so it works the same whether the
/// fingers reversed early or after a long swipe.
var gSwipeIntentProgress: Double = 0

/// Whether the intercepted horizontal swipe started inside the Mission Control
/// overview. Captured at Began (the overview may already be sliding by the time
/// direction resolves) and decides which posting recipe replaces the gesture.
var gSwipeInOverview: Bool = false

/// Whether a Mission Control entry/dismissal swipe has been replaced and the
/// rest of its physical event sequence must be swallowed.
var gMissionControlSwipeTracking: Bool = false

/// Sign of the *physical* vertical travel the claimed gesture last acted on
/// (`0` when none). The transition posted for it toggles between the desktop
/// and one overview, so the opposite travel always undoes it and a reversal
/// needs no further state resolution.
var gMissionControlIntentSign: Int = 0

/// Furthest physical vertical progress reached since `gMissionControlIntentSign`
/// was last acted on. Same reversal measure as `gSwipeIntentProgress`.
var gMissionControlIntentProgress: Double = 0

/// A vertical gesture prefix held until the first non-zero progress sample
/// identifies the direction. Copied events are replayed through the tap proxy
/// when Space Rabbit does not claim the gesture.
var gPendingMissionControlEvents: [CGEvent] = []

/// Exact overview state captured with the pending vertical Began. The live
/// state may already be transitioning by the time Changed reveals direction.
var gPendingMissionControlOverviewState: DockOverviewState?

/// "Natural scrolling" as it read when the claimed vertical gesture began.
///
/// The window server reports vertical gesture travel in the orientation this
/// setting selects, but the Dock's own meaning for the gesture does not move
/// with it, so the sign has to be corrected before it is trusted (see
/// `verticalDirection(forPhysicalSign:)`). It is sampled once per gesture
/// rather than per event: a toggle landing mid-gesture would otherwise let the
/// reversal disagree with the opening decision and post a transition that
/// compounds instead of undoing.
var gMissionControlNaturalScrolling: Bool = true

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
    let motion: Int64
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

/// Virtual keycode emitted by the Fn/Globe key on Apple keyboards.
let kFnKeycode: Int64 = 63

/// Virtual keycodes the shortcut recorder acts on rather than records:
/// Escape cancels, either Delete clears the binding.
let kEscapeKeycode: Int64        = 53
let kDeleteKeycode: Int64        = 51
let kForwardDeleteKeycode: Int64 = 117

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

    /// Non-alphanumeric keycodes and the glyphs the recorder shows for them.
    /// Anything absent from this table and from `functionKeyLabels` is
    /// labelled with the character the key produces unmodified.
    static let specialKeyLabels: [Int64: String] = [
        36: "↩", 48: "⇥", 49: "␣", kDeleteKeycode: "⌫", kEscapeKeycode: "⎋",
        57: "⇪", kFnKeycode: "fn", 115: "↖", 116: "⇞", kForwardDeleteKeycode: "⌦",
        119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Non-F keys whose events carry `.maskSecondaryFn` automatically even
    /// when the physical Fn key is not held. AppKit classifies these as
    /// function/navigation keys, so that synthesized flag must be ignored
    /// during modifier matching.
    private static let implicitFunctionFlagKeycodes: Set<Int64> = [
        71,                              // Keypad Clear
        114,                             // Help / Insert
        115, 116, 119, 121,              // Home, Page Up, End, Page Down
        kForwardDeleteKeycode,
        123, 124, 125, 126,              // Arrow keys
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

/// True while the Preferences ignore-list recorder is armed. Unlike the
/// cycle-shortcut recorder — whose local monitor sees events delivered to
/// our own windows — this recording is performed by the event tap itself,
/// because the chords being recorded are other apps' registered global
/// hotkeys and never reach this app through normal dispatch. While set,
/// the tap swallows every key-down and hands it to
/// `gIgnoredHotkeyCaptureHandler` instead (EventTap.swift).
var gIsRecordingIgnoredHotkey = false

/// Receives each key-down the tap captures while
/// `gIsRecordingIgnoredHotkey` is set, dispatched on the main queue.
/// Installed by the recording control (ShortcutRecorder.swift), which owns
/// validation and cancellation.
var gIgnoredHotkeyCaptureHandler: ((CGEvent) -> Void)?

/// Keycode of a key-down swallowed by ignore-list recording whose key-up
/// is still owed a swallow, or `nil`.
var gIgnoredRecordingClaimedKeycode: Int64?

/// Global hotkeys after which auto-follow must stand down, as recorded by
/// the user in Settings > Features. These are hotkeys that summon an app's
/// popup onto the *current* space — Arc's Little Arc, iTerm2's hotkey
/// window — where chasing the app's other windows would be wrong (see
/// `gLastHotkeyChordTime`). Empty by default, so auto-follow behaves
/// exactly as before until the user lists something. Persisted under
/// `Defaults.autoFollowIgnoredHotkeys`.
var gAutoFollowIgnoredChords: [CycleShortcut] = []

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

/// Binding for the "Mission Control" system hotkey (default: Control + Up
/// Arrow). `nil` when the hotkey is disabled in System Settings. The dedicated
/// Mission Control key in the function row is matched separately — it is
/// hardware, not a configurable hotkey.
var gBindingMissionControl: KeyBinding? = (keycode: 126, mods: .maskControl)

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
    static let instantMissionControl  = "spacerabbit.instantMissionControl"
    static let cycleShortcutEnabled   = "spacerabbit.cycleShortcut.enabled"
    static let cycleShortcutKeycode   = "spacerabbit.cycleShortcut.keycode"
    static let cycleShortcutModifiers = "spacerabbit.cycleShortcut.modifiers"
    static let cycleShortcutLabel     = "spacerabbit.cycleShortcut.label"
    /// Array of dictionaries (`keycode`, `modifiers`, `label`) — the
    /// auto-follow ignore list (see `gAutoFollowIgnoredChords`).
    static let autoFollowIgnoredHotkeys = "spacerabbit.autoFollowIgnoredHotkeys"
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

/// Reads the auto-follow ignore list into `gAutoFollowIgnoredChords`.
/// Counterpart of `persistAutoFollowIgnoredChords()`. Malformed entries
/// are skipped rather than discarding the whole list.
func loadAutoFollowIgnoredChords() {
    let stored = UserDefaults.standard.array(forKey: Defaults.autoFollowIgnoredHotkeys)
        as? [[String: Any]] ?? []
    gAutoFollowIgnoredChords = stored.compactMap { entry in
        guard let keycode = (entry["keycode"]   as? NSNumber)?.int64Value,
              let raw     = (entry["modifiers"] as? NSNumber)?.uint64Value,
              let label   = entry["label"]      as? String
        else { return nil }
        return CycleShortcut(keycode: keycode,
                             modifiers: CGEventFlags(rawValue: raw),
                             keyLabel: label)
    }
}

/// Writes the auto-follow ignore list.
func persistAutoFollowIgnoredChords() {
    UserDefaults.standard.set(
        gAutoFollowIgnoredChords.map { [
            "keycode":   NSNumber(value: $0.keycode),
            "modifiers": NSNumber(value: $0.modifiers.rawValue),
            "label":     $0.keyLabel,
        ] },
        forKey: Defaults.autoFollowIgnoredHotkeys
    )
}

/// Reads the configurable cycle shortcut and its enabled state into the
/// globals. Counterpart of `persistCycleShortcut()` — the negative keycode
/// written there for an explicitly-cleared recorder resolves back to `nil`,
/// with the feature forced off since it has nothing left to match.
func loadCycleShortcut() {
    let defaults = UserDefaults.standard
    gCycleShortcutEnabled = defaults.bool(forKey: Defaults.cycleShortcutEnabled)

    let keycode = (defaults.object(forKey: Defaults.cycleShortcutKeycode)
                     as? NSNumber)?.int64Value ?? kFnKeycode
    guard keycode >= 0 else {
        gCycleShortcut        = nil
        gCycleShortcutEnabled = false
        return
    }

    let rawModifiers = (defaults.object(forKey: Defaults.cycleShortcutModifiers)
                          as? NSNumber)?.uint64Value ?? 0
    gCycleShortcut = CycleShortcut(
        keycode: keycode,
        modifiers: CGEventFlags(rawValue: rawModifiers),
        keyLabel: defaults.string(forKey: Defaults.cycleShortcutLabel)
            ?? CycleShortcut.fn.keyLabel
    )
}

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

    // Whether a shortcut is configured decides whether modifier transitions
    // are worth watching at all. Both Preferences paths that change it land
    // here, so this is the one place that has to say so.
    syncKeyboardAuxiliaryTaps()
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
