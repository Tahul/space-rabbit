/*
 * EventTap.swift — Feature 1: Instant space switch via event tap
 *
 * Installs a CGEvent tap at the session level to intercept keyDown
 * events that match the user's "Move left/right a space" or
 * "Switch to Desktop N" shortcuts. It also observes keyUp,
 * flagsChanged, and systemDefined events so the configurable cycle
 * shortcut can safely support both ordinary chords and bare Fn.
 *
 * When the shortcut is detected:
 *   1. The original key event is swallowed (returns nil to the tap)
 *   2. A synthetic DockSwipe gesture pair is posted (see SpaceSwitching.swift)
 *   3. The Dock handles the gesture and switches spaces instantly
 *
 * The same tap owns the keyboard triggers for Instant Mission Control —
 * the dedicated function-row key and the "Mission Control" system hotkey.
 * Those are swallowed too, and replaced with the controlled vertical
 * DockSwipe stream the trackpad gesture already uses.
 *
 * The tap also re-enables itself if macOS disables it due to timeout
 * or user input (a safety measure built into CGEvent taps).
 */

import CoreGraphics
import Foundation

// MARK: - Constants

/// The set of modifier keys we care about when matching shortcuts.
/// Any modifier not in this set (e.g. Fn, CapsLock) is ignored,
/// so pressing Fn+Control+Arrow still matches a Control+Arrow shortcut.
private let kRelevantModifiers: CGEventFlags = [
    .maskControl, .maskCommand, .maskAlternate, .maskShift
]

/// Tracks a possible bare-Fn press until release. The switch happens on
/// release so Fn can still be used as a modifier without cycling spaces.
private var gFnPressState: BareFnPressState = .idle

/// Key-down swallowed for an ordinary configured cycle shortcut. Its key-up
/// is swallowed too so the frontmost app never receives an orphan release.
private var gCycleShortcutActiveKeycode: Int64?

/// Key-down swallowed for a Mission Control trigger. Its key-up is swallowed
/// too, so Dock never sees a release whose press it never received — the
/// dedicated hardware key gives no way to tell which of the two it acts on.
private var gMissionControlActiveKeycode: Int64?

/// Virtual keycode reported by the dedicated Mission Control key on Apple
/// keyboards (function row, F3 in its default top-row mode). It is a distinct
/// keycode, not F3 with a modifier, so it arrives the same way whichever way
/// "Use F1, F2, etc. as standard function keys" is set. Measured on macOS 26:
/// a plain key-down/key-up pair carrying only the automatic Fn flag, with no
/// DockSwipe of its own — Dock runs its animated transition internally.
private let kMissionControlKeycode: Int64 = 160

// MARK: - Primary Tap Lifecycle

/// Creates the session-level keyDown tap, attaches it to the main run loop
/// and enables it. Stores the tap and its source in `gTap` / `gTapSource`.
///
/// Called once at startup (main.swift, where a failure is fatal) and again
/// by `reviveKeyboardTapsIfNeeded()` when the tap has to be rebuilt.
///
/// - Returns: `false` when the tap could not be created (e.g. Accessibility
///   permission missing or revoked).
func installEventTap() -> Bool {
    let keyDownMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let primary = makeKeyboardTap(mask: keyDownMask) else { return false }

    CGEvent.tapEnable(tap: primary.tap, enable: true)
    gTap       = primary.tap
    gTapSource = primary.source
    return true
}

/// Brings dead keyboard taps back to life after system sleep or screen lock.
///
/// The self-re-enable in `eventTapCallback` only works while the callback is
/// still being invoked: macOS delivers `tapDisabledByTimeout` /
/// `tapDisabledByUserInput` *through the tap itself*. A tap disabled — or its
/// Mach port invalidated outright — while the process is suspended around
/// sleep or lock never receives that notice and stays dead until relaunch.
/// Runs from the wake/unlock observers and the periodic flush timer in
/// main.swift; a healthy tap set makes this a cheap no-op.
func reviveKeyboardTapsIfNeeded() {
    // Primary keyDown tap: always-on, so any disable found here is a system
    // disable that the callback never got to see.
    if let tap = gTap, CFMachPortIsValid(tap) {
        if !CGEvent.tapIsEnabled(tap: tap) {
            fputs("Space Rabbit: keyboard tap was disabled — re-enabling after wake/unlock\n", stderr)
            resetKeyTracking()
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    } else {
        // Port invalidated — its run loop source died with it; rebuild.
        fputs("Space Rabbit: keyboard tap port died — rebuilding after wake/unlock\n", stderr)
        resetKeyTracking()
        if let source = gTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        gTap       = nil
        gTapSource = nil
        if !installEventTap() {
            fputs("Space Rabbit: failed to rebuild keyboard tap\n", stderr)
        }
    }

    // Auxiliary taps. Rebuild both when either port died; otherwise refresh
    // the cached enabled flags from reality — a system disable during the
    // suspension leaves them stale, and setKeyboardTap only pushes state to
    // the window server on a flag change, so a stale flag pins the tap dead.
    let claimedPortDied  = gClaimedKeyTap.map { !CFMachPortIsValid($0) } ?? false
    let modifierPortDied = gModifierKeyTap.map { !CFMachPortIsValid($0) } ?? false

    if claimedPortDied || modifierPortDied {
        fputs("Space Rabbit: auxiliary keyboard tap port died — rebuilding after wake/unlock\n", stderr)
        resetKeyTracking()
        for tap in [gClaimedKeyTap, gModifierKeyTap] {
            if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: false) }
        }
        for source in [gClaimedKeyTapSource, gModifierKeyTapSource] {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        gClaimedKeyTap         = nil
        gClaimedKeyTapSource   = nil
        gClaimedKeyTapEnabled  = false
        gModifierKeyTap        = nil
        gModifierKeyTapSource  = nil
        gModifierKeyTapEnabled = false
        installAuxiliaryKeyboardTaps()
    } else {
        var cacheWasStale = false
        if let tap = gClaimedKeyTap {
            let actual = CGEvent.tapIsEnabled(tap: tap)
            if actual != gClaimedKeyTapEnabled { gClaimedKeyTapEnabled = actual; cacheWasStale = true }
        }
        if let tap = gModifierKeyTap {
            let actual = CGEvent.tapIsEnabled(tap: tap)
            if actual != gModifierKeyTapEnabled { gModifierKeyTapEnabled = actual; cacheWasStale = true }
        }
        if cacheWasStale {
            // Any claim from before the suspension is stale; drop it so the
            // sync below resolves each tap to the state it should be in now.
            resetKeyTracking()
            syncKeyboardAuxiliaryTaps()
        }
    }
}

// MARK: - Auxiliary Tap Lifecycle

/// Creates the two on-demand companions to `gTap`, both left disabled.
///
/// Called once at startup, right after the primary tap. A failure here is
/// logged and tolerated — see the call site in `main.swift`.
func installAuxiliaryKeyboardTaps() {
    let claimedKeyMask = CGEventMask(1 << CGEventType.keyUp.rawValue)
                       | CGEventMask(1 << kCGEventTypeSystemDefined.rawValue)
    let modifierMask   = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

    if let claimed = makeKeyboardTap(mask: claimedKeyMask) {
        gClaimedKeyTap       = claimed.tap
        gClaimedKeyTapSource = claimed.source
    } else {
        fputs("Space Rabbit: failed to create claimed-key tap\n", stderr)
    }

    if let modifier = makeKeyboardTap(mask: modifierMask) {
        gModifierKeyTap       = modifier.tap
        gModifierKeyTapSource = modifier.source
    } else {
        fputs("Space Rabbit: failed to create modifier key tap\n", stderr)
    }

    syncKeyboardAuxiliaryTaps()
}

/// Creates one session tap feeding `eventTapCallback`, added to the run loop
/// but left disabled.
///
/// - Parameter mask: The event types the tap should receive.
/// - Returns: The tap and its run loop source, or `nil` on failure.
private func makeKeyboardTap(mask: CGEventMask) -> (tap: CFMachPort, source: CFRunLoopSource)? {
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: eventTapCallback,
        userInfo: nil
    ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
        return nil
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: false)
    return (tap, source)
}

/// Brings both auxiliary taps in line with the state that makes them useful.
///
/// Runs from a `defer` covering every exit of `eventTapCallback`, so no branch
/// can leave one enabled after the press it belonged to ended. It is also
/// called wherever the cycle shortcut itself changes, since that happens
/// outside the event path — and because the callback re-runs it on the very
/// next key-down, a missed call site self-corrects within one keystroke rather
/// than stranding the tap.
func syncKeyboardAuxiliaryTaps() {
    // A claimed press still owes macOS a swallowed release, and a live bare-Fn
    // candidate still needs to see whether another key cancels it.
    let claimedKeyListening = gCycleShortcutActiveKeycode != nil
        || gMissionControlActiveKeycode != nil
        || gFnPressState.isDown

    // Physical Fn tracking only exists to serve a configured cycle shortcut.
    let modifierListening = gCycleShortcutEnabled
        && gCycleShortcut != nil
        && !gIsRecordingCycleShortcut

    setKeyboardTap(gClaimedKeyTap, enabled: claimedKeyListening, state: &gClaimedKeyTapEnabled)
    setKeyboardTap(gModifierKeyTap, enabled: modifierListening, state: &gModifierKeyTapEnabled)
}

/// Pushes a tap's enabled state to the window server only when it changed.
///
/// - Parameters:
///   - tap: The tap to update, if it was created.
///   - enabled: The state it should be in.
///   - state: The cached flag tracking what was last applied.
private func setKeyboardTap(_ tap: CFMachPort?, enabled: Bool, state: inout Bool) {
    guard let tap, enabled != state else { return }

    CGEvent.tapEnable(tap: tap, enable: enabled)
    state = enabled
}

// MARK: - Configurable Space Cycling

/// Clears the in-progress bare-Fn candidate.
private func resetFnPressTracking() {
    gFnPressState.reset()
}

/// Clears all state tied to a key press Space Rabbit swallowed.
private func resetKeyTracking() {
    resetFnPressTracking()
    gCycleShortcutActiveKeycode  = nil
    gMissionControlActiveKeycode = nil
}

/// Moves to the next space on the display under the cursor, wrapping from
/// the last space back to the first.
///
/// Only called once the configured cycle shortcut has matched — both guards
/// below scan the window list or the space layout, too heavy to run for every
/// event passing through the tap.
///
/// - Returns: `true` when a switch was posted. `false` means Space Rabbit
///   stood down and the caller should let macOS handle the key natively.
@discardableResult
private func cycleToNextSpace() -> Bool {
    // Preserve native window-manager behavior while a window is dragged.
    // Cheapest of the three checks, so it runs first.
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left)
    else { return false }

    // Mission Control navigates its own carousel — see isMissionControlActive().
    guard !isMissionControlActive() else { return false }

    let (spaceIDs, currentIdx) = getSpaceList()
    guard currentIdx >= 0, spaceIDs.count > 1 else { return false }

    let targetIdx = (currentIdx + 1) % spaceIDs.count
    guard case .switched = switchToSpace(spaceIDs[targetIdx]) else { return false }

    gLastSpaceSwitchTime = Date()
    gMenu?.recordSwitch()
    return true
}

// MARK: - Keyboard Mission Control

/// Whether Space Rabbit may drive the Mission Control overview's space
/// carousel in place of a matched one-step Space shortcut.
///
/// Called only once `isMissionControlActive()` has reported an overview, so
/// this resolves the exact state: App Exposé, Show Desktop and unreadable
/// private state keep macOS's native handling, the same rule the intercepted
/// in-overview swipe follows.
///
/// - Returns: `true` when the overview is Mission Control and the feature is
///   available.
private func canDriveOverviewSpaceSwitch() -> Bool {
    gInstantMissionControlEnabled
        && supportsInstantMissionControlInterception()
        && currentDockOverviewState() == .missionControl
}

/// Whether this key press asks macOS for Mission Control — either the
/// dedicated function-row key or the "Mission Control" system hotkey.
///
/// - Parameters:
///   - keycode: The pressed key's virtual keycode.
///   - flags: The event's modifier flags.
/// - Returns: `true` when the press is a Mission Control trigger.
private func isMissionControlTrigger(keycode: Int64, flags: CGEventFlags) -> Bool {
    let mods = flags.intersection(kRelevantModifiers)

    // The hardware key carries the automatic Fn flag, which is outside
    // kRelevantModifiers — any real modifier makes it a different chord.
    if keycode == kMissionControlKeycode { return mods.isEmpty }

    guard let binding = gBindingMissionControl else { return false }
    return keycode == binding.keycode && mods == binding.mods
}

/// Replaces a keyboard-triggered Mission Control transition with the same
/// controlled DockSwipe stream the trackpad interception posts, so the
/// keyboard follows the transition-speed slider like every other path.
///
/// Pressing the key is a toggle, so the direction comes from what is on
/// screen: the desktop enters, Mission Control dismisses. Show Desktop and
/// unreadable private state stay native.
///
/// App Exposé stays native here even though the vertical *gesture* path now
/// drives it, because the key means something different inside it: an upward
/// swipe from App Exposé dismisses it, while the Mission Control key from App
/// Exposé moves across to Mission Control. There is no vertical transition
/// that reproduces that, so the toggle's direction inference does not hold and
/// the key is passed through.
///
/// Only called once a trigger has matched: the state lookup scans the window
/// list, too heavy to run for every keystroke passing through the tap.
///
/// - Parameter proxy: The active event tap proxy, used to inject the
///   replacement gesture in order ahead of the swallowed key event.
/// - Returns: `true` when a transition was posted. `false` means Space Rabbit
///   stood down and the caller should let macOS handle the key natively.
private func triggerMissionControlTransition(proxy: CGEventTapProxy) -> Bool {
    guard supportsInstantMissionControlInterception() else { return false }

    let direction: Int
    switch currentDockOverviewState() {
    case .desktop:        direction = 1
    case .missionControl: direction = -1
    case .appExpose, nil: return false
    }

    guard postMissionControlTransition(proxy: proxy, direction: direction)
    else { return false }

    gMenu?.recordSwitch()
    return true
}

// MARK: - Event Tap Callback
//
// This is a C-compatible global function used as the CGEvent tap callback.
// It cannot be a method or closure — the CGEvent API requires a plain
// function pointer with the exact `CGEventTapCallBack` signature.

/// CGEvent tap callback that intercepts space-switch keyboard shortcuts.
///
/// Called for the keyboard event types in the event tap's mask system-wide
/// (requires Accessibility permission).
/// Returns `nil` to swallow the event (preventing the default animated switch),
/// or `Unmanaged.passUnretained(event)` to let it through unchanged.
///
/// - Parameters:
///   - proxy: The event tap proxy (unused).
///   - type: The event type — may be `keyDown`, `tapDisabledByTimeout`, etc.
///   - event: The intercepted event.
///   - userInfo: User-provided context pointer (unused).
/// - Returns: The event to pass downstream, or `nil` to swallow it.
func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                      event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)

    // The auxiliary taps are only worth their wakeups while a press is claimed
    // or a cycle shortcut is configured, and any branch below can change that.
    defer { syncKeyboardAuxiliaryTaps() }

    // macOS may disable our tap if it takes too long to process an event
    // or if it suspects misbehavior. Re-enable it immediately to stay alive.
    //
    // The notification does not identify which of the three taps was disabled,
    // so the always-on one is re-enabled unconditionally (a redundant enable is
    // harmless) and the auxiliaries are left to the `defer` above, which now
    // resolves to "disabled" because the reset dropped every claim.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        resetKeyTracking()
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return passthrough
    }

    // While Preferences records a replacement shortcut, let AppKit receive
    // every candidate event without the existing global binding firing.
    if gIsRecordingCycleShortcut {
        resetKeyTracking()
        return passthrough
    }

    // Only process keyboard events while the master switch is enabled.
    guard type == .keyDown || type == .keyUp || type == .flagsChanged
            || type == kCGEventTypeSystemDefined,
          gEnabled else {
        resetKeyTracking()
        return passthrough
    }

    // At the "Normal" transition speed the user wants macOS's native
    // animated switch — let every shortcut through untouched so the OS
    // handles it exactly as if Space Rabbit weren't running.
    guard !isNativeSwitchSpeed() else {
        resetKeyTracking()
        return passthrough
    }

    let flags   = event.flags
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)

    // Track physical Fn transitions for every configured cycle shortcut. That
    // lets ordinary navigation-key bindings distinguish their implicit
    // function flag from an actual extra Fn modifier. A configured bare Fn is
    // deferred until release and cancelled if another key or modifier is used.
    if type == .flagsChanged {
        guard gCycleShortcutEnabled, let cycleShortcut = gCycleShortcut else {
            resetFnPressTracking()
            return passthrough
        }

        guard keycode == kFnKeycode else {
            gFnPressState.markChorded()
            return passthrough
        }

        if flags.contains(.maskSecondaryFn) {
            // Only a new up -> down transition starts a bare-Fn candidate.
            // Repeated down events must not erase evidence that Fn was used
            // with another key.
            // A modifier may already be held before Fn goes down, so its
            // flagsChanged event occurred before this candidate existed.
            gFnPressState.begin(
                usedAsModifier: !flags.intersection(kRelevantModifiers).isEmpty
            )
        } else {
            let wasBarePress = gFnPressState.finish()
            // A bare-Fn binding owns the key either way: when the cycle stands
            // down (Mission Control, a window being dragged, unknown layout)
            // the tap simply performs no switch. There is no native Fn
            // behavior worth restoring mid-press.
            if cycleShortcut.isBareFn, wasBarePress { cycleToNextSpace() }
        }
        return cycleShortcut.isBareFn ? nil : passthrough
    }

    // Any ordinary or system-defined keyboard event between Fn down and up
    // makes this a chord, not a bare-Fn tap. keyUp is included as a safety
    // net for hardware whose modified key does not expose a matching keyDown.
    gFnPressState.markChorded()

    // Swallow the release paired with a key press we already claimed.
    if type == .keyUp {
        if gMissionControlActiveKeycode == keycode {
            gMissionControlActiveKeycode = nil
            return nil
        }
        guard gCycleShortcutActiveKeycode == keycode else { return passthrough }
        gCycleShortcutActiveKeycode = nil
        return nil
    }

    // systemDefined is observed only for bare-Fn chord detection. Shortcut
    // matching itself applies to ordinary keyDown events.
    guard type == .keyDown else { return passthrough }

    // Keyboard-triggered Mission Control. Matched before the Space shortcuts
    // and independent of the Instant Space switch toggle — this is the Instant
    // Mission Control feature's third trigger, alongside the vertical trackpad
    // gesture the swipe tap owns.
    if gInstantMissionControlEnabled,
       isMissionControlTrigger(keycode: keycode, flags: flags) {
        // One transition per physical press: a repeat is swallowed only when
        // the press it belongs to was ours to begin with.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return gMissionControlActiveKeycode == keycode ? nil : passthrough
        }

        // Standing down hands the key back to macOS, and leaves no active
        // keycode, so the paired key-up passes through as well.
        guard triggerMissionControlTransition(proxy: proxy) else { return passthrough }

        gMissionControlActiveKeycode = keycode
        return nil
    }

    // Match the user-recorded cycle shortcut before the macOS Space bindings.
    // This feature is independent of the Instant Space switch toggle.
    if gCycleShortcutEnabled,
       let shortcut = gCycleShortcut,
       !shortcut.isBareFn,
       keycode == shortcut.keycode,
       (!gFnPressState.isDown || shortcut.isFunctionKey),
       flags.intersection(shortcut.matchingModifierMask) == shortcut.modifiers {
        // Cycle once per physical press: a repeat is swallowed only when the
        // press it belongs to was ours to begin with.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return gCycleShortcutActiveKeycode == keycode ? nil : passthrough
        }

        // Standing down (Mission Control, a dragged window, unknown layout)
        // hands the key back to macOS rather than eating it — and leaves no
        // active keycode, so the paired key-up passes through as well.
        guard cycleToNextSpace() else { return passthrough }

        gCycleShortcutActiveKeycode = keycode
        return nil
    }

    // The system Space shortcuts still follow the Instant Space switch toggle.
    guard gInstantSwitchEnabled else { return passthrough }

    // Window managers such as Rectangle Pro and Raycast move a window to an
    // adjacent Space by holding its title bar while invoking the system Space
    // shortcut. Replacing that shortcut with a DockSwipe switches Spaces but
    // leaves the held window behind, so preserve macOS's native handling while
    // the primary mouse button is down.
    if CGEventSource.buttonState(.combinedSessionState, button: .left) {
        return passthrough
    }

    // Check that exactly the required modifiers are held (no extras).
    // This prevents false positives when e.g. Cmd+Control+Arrow is pressed
    // but we only want Control+Arrow.
    let eventMods = flags.intersection(kRelevantModifiers)

    // Direct "Switch to Desktop N" — jump straight to that desktop.
    // Mission Control numbers user desktops globally across displays and
    // skips fullscreen spaces, so the lookup must match that numbering
    // exactly (getUserDesktops, not the cursor display's full space list).
    for (idx, binding) in gSpaceKeys.enumerated() {
        guard let binding,
              keycode == binding.keycode,
              eventMods == binding.mods else { continue }

        // Mission Control navigates its own carousel — see
        // isMissionControlActive(). Checked only once a shortcut has
        // matched: the lookup scans the window list, too heavy to run
        // for every keystroke passing through the tap.
        guard !isMissionControlActive() else { return passthrough }

        let desktops = getUserDesktops()

        // Layout unknown or no such desktop — pass the key through and
        // let macOS decide natively instead of eating the shortcut.
        guard idx < desktops.count else { return passthrough }

        switch switchToSpace(desktops[idx]) {
        case .switched:
            gLastSpaceSwitchTime = Date()
            gMenu?.recordSwitch()
            return nil
        case .alreadyThere:
            // Swallow: the native handler would do nothing useful either
            return nil
        case .declined:
            // We stood down (cross-display target at an animated speed,
            // layout mismatch): let macOS perform its native switch.
            return passthrough
        }
    }

    // Determine switch direction by matching keycode + exact modifiers
    // against the per-direction bindings. The two sides are independent:
    // they may carry different modifiers, and either may be nil (hotkey
    // disabled in System Settings — intercept nothing for it).
    let direction: Int
    if      let b = gBindingLeft,  keycode == b.keycode, eventMods == b.mods { direction = -1 }
    else if let b = gBindingRight, keycode == b.keycode, eventMods == b.mods { direction = +1 }
    else                                                                     { return passthrough }

    // Same lookup as above, for the left/right shortcuts — but these are the
    // one-step shortcuts the overview's own carousel navigates, so with Instant
    // Mission Control on they are driven rather than handed back to macOS.
    // Anything else on screen (App Exposé, Show Desktop, unreadable state)
    // still stands down.
    let inOverview = isMissionControlActive()
    if inOverview {
        guard canDriveOverviewSpaceSwitch() else { return passthrough }
    }

    // Bounds check: don't switch past the first or last space
    let (spaceIDs, currentIdx) = getSpaceList()

    // Layout unknown (private-API failure) — stand down and let macOS
    // handle the shortcut natively rather than posting a blind gesture,
    // which bounces into a blank space at the edges (issue #6)
    guard currentIdx >= 0 else { return passthrough }

    let targetIdx = currentIdx + direction
    guard targetIdx >= 0, targetIdx < spaceIDs.count else {
        // Already at the edge — swallow the event to prevent
        // the default animated "bounce" effect
        return nil
    }

    // Post the synthetic gesture and record the switch for statistics. Inside
    // the overview the desktop's fully-committed boundary jump cannot be
    // reused — it is evaluated against the overview's own state and lands back
    // where it started (issue #16) — so the segmented carousel stream goes out
    // instead, exactly as the intercepted in-overview swipe does.
    let posted = inOverview
        ? postOverviewSpaceSwitch(proxy: proxy, direction: direction)
        : postSwitchGesture(direction: direction)

    if posted {
        gLastSpaceSwitchTime = Date()
        gMenu?.recordSwitch()
    }

    // Return nil to swallow the original key event, preventing macOS
    // from performing its default animated space switch
    return nil
}
