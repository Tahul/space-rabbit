/*
 * EventTap.swift — Feature 1: Instant space switch via event tap
 *
 * Installs a CGEvent tap at the session level to intercept keyDown
 * events that match the user's "Move left/right a space" or
 * "Switch to Desktop N" shortcuts.
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

// MARK: - Event Tap Callback
//
// This is a C-compatible global function used as the CGEvent tap callback.
// It cannot be a method or closure — the CGEvent API requires a plain
// function pointer with the exact `CGEventTapCallBack` signature.

/// CGEvent tap callback that intercepts space-switch keyboard shortcuts.
///
/// Called for every `keyDown` event system-wide (requires Accessibility permission).
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
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return passthrough
    }

    // Only process keyDown events when both the master switch and
    // the instant-switch feature are enabled
    guard type == .keyDown, gEnabled, gInstantSwitchEnabled else {
        return passthrough
    }

    // At the "Normal" transition speed the user wants macOS's native
    // animated switch — let every shortcut through untouched so the OS
    // handles it exactly as if Space Rabbit weren't running.
    guard !isNativeSwitchSpeed() else {
        return passthrough
    }

    let flags   = event.flags
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)

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
