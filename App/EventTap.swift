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

// MARK: - Configurable Space Cycling

/// Clears the in-progress bare-Fn candidate.
private func resetFnPressTracking() {
    gFnPressState.reset()
}

/// Clears all state associated with an in-progress cycle shortcut.
private func resetCycleShortcutTracking() {
    resetFnPressTracking()
    gCycleShortcutActiveKeycode = nil
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

    // macOS may disable our tap if it takes too long to process an event
    // or if it suspects misbehavior. Re-enable it immediately to stay alive.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        resetCycleShortcutTracking()
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return passthrough
    }

    // While Preferences records a replacement shortcut, let AppKit receive
    // every candidate event without the existing global binding firing.
    if gIsRecordingCycleShortcut {
        resetCycleShortcutTracking()
        return passthrough
    }

    // Only process keyboard events while the master switch is enabled.
    guard type == .keyDown || type == .keyUp || type == .flagsChanged
            || type == kCGEventTypeSystemDefined,
          gEnabled else {
        resetCycleShortcutTracking()
        return passthrough
    }

    // At the "Normal" transition speed the user wants macOS's native
    // animated switch — let every shortcut through untouched so the OS
    // handles it exactly as if Space Rabbit weren't running.
    guard !isNativeSwitchSpeed() else {
        resetCycleShortcutTracking()
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

    // Swallow the release paired with an ordinary configured shortcut.
    if type == .keyUp {
        guard gCycleShortcutActiveKeycode == keycode else { return passthrough }
        gCycleShortcutActiveKeycode = nil
        return nil
    }

    // systemDefined is observed only for bare-Fn chord detection. Shortcut
    // matching itself applies to ordinary keyDown events.
    guard type == .keyDown else { return passthrough }

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

    // Same stand-down as above, for the left/right shortcuts
    guard !isMissionControlActive() else { return passthrough }

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

    // Post the synthetic gesture and record the switch for statistics
    if postSwitchGesture(direction: direction) {
        gLastSpaceSwitchTime = Date()
        gMenu?.recordSwitch()
    }

    // Return nil to swallow the original key event, preventing macOS
    // from performing its default animated space switch
    return nil
}
