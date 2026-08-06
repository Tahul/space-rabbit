/*
 * SwipeIntercept.swift — Feature 3: Instant trackpad swipe
 *
 * Removes the slide animation from real trackpad swipes.
 *
 * macOS turns a horizontal 3-finger (or 4-finger, per the trackpad
 * setting) swipe into private DockSwipe events — the same event family
 * Space Rabbit synthesizes for its other features. A second CGEvent tap
 * listens for those private gesture event types, swallows the user's
 * animated swipe as it begins, reads its direction from the first
 * progress sample, and re-posts it as an instant switch:
 *
 *   1. Began   — start tracking, swallow (the animated switch never starts)
 *   2. Changed — first non-zero progress reveals the direction; fire the
 *                instant switch once, keep swallowing
 *   3. Ended   — fallback: if nothing fired yet (a very quick flick can
 *                skip Changed), use the final velocity's sign; reset
 *   4. Cancelled — reset without firing
 *
 * Companion generic gesture events paired with a tracked swipe are
 * swallowed too, so the Dock never sees any half of the real gesture.
 *
 * Because Space Rabbit's own synthetic gestures are posted into the same
 * session tap, they would loop right back into this tap. A passthrough
 * counter (`gSwipePassthroughCount`) is incremented for every synthetic
 * event just before it is posted, and events are waved through while the
 * counter drains (same technique as joshuarli/iss, from which this whole
 * interception scheme is ported).
 *
 * Unlike the keyboard tap (installed once at startup), this tap is created
 * and torn down on demand: gesture events are high-frequency while fingers
 * touch the pad, so the tap only exists while the feature is active.
 */

import CoreGraphics
import Foundation

// MARK: - Constants

/// Value of `kCGEventGestureSwipeMotion` identifying a horizontal swipe.
/// Vertical swipes (Mission Control / App Exposé) carry other values and
/// are never intercepted.
private let kGestureMotionHorizontal: Int64 = 1

/// Whether the running macOS release inverted the reported swipe
/// direction sign. macOS 26 reports horizontal swipe progress/velocity
/// with the OPPOSITE sign of earlier releases; macOS 27 inverted it back
/// (handled first via `requiresEventAugmentation()` in `isRightSwipe`).
/// Mirrors joshuarli/iss's ISS_SWIPE_DIRECTION_REVERSED, evaluated at
/// runtime instead of build time since one binary spans macOS 15…27+.
private let kSwipeDirectionReversed: Bool =
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26

// MARK: - Tap Lifecycle

/// Creates or tears down the swipe-intercept tap to match the current
/// feature state (`gEnabled && gTrackpadSwipeEnabled`).
///
/// Called at startup and from every place that flips either toggle (the
/// menu bar dropdown, the master switch, and the settings window). Safe to
/// call redundantly — it no-ops when the tap already matches the state.
func updateSwipeTap() {
    let shouldRun = gEnabled && gTrackpadSwipeEnabled

    if shouldRun, gSwipeTap == nil {
        let mask = CGEventMask((1 << UInt64(kCGSEventGesture))
                             | (1 << UInt64(kCGSEventDockControl)))

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: swipeTapCallback,
            userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            fputs("Space Rabbit: failed to create swipe intercept tap\n", stderr)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        gSwipeTap       = tap
        gSwipeTapSource = source
        resetSwipeIntercept()
    } else if !shouldRun, let tap = gSwipeTap {
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = gSwipeTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        gSwipeTap       = nil
        gSwipeTapSource = nil
        resetSwipeIntercept()
    }
}

/// Clears all per-gesture tracking state and the synthetic-event
/// passthrough counter. Called whenever the tap's continuity breaks
/// (created, torn down, or re-enabled after a system disable) — stale
/// state from before the break must not leak into the next gesture.
func resetSwipeIntercept() {
    gSwipeTracking          = false
    gSwipeFired             = false
    gSwipePassthroughCount  = 0
}

/// Pre-counts synthetic gesture events about to be posted, so the
/// swipe-intercept tap passes them through instead of re-intercepting
/// them (which would loop: intercept → post → intercept → …).
///
/// Called by the gesture posting code in SpaceSwitching.swift right
/// before each event pair goes out. No-op while the tap is not installed,
/// so the counter can never accumulate while nothing drains it.
///
/// - Parameter eventCount: How many events are about to be posted
///   (a pair = one dock control + one gesture envelope = 2).
func markSyntheticGesturePosted(eventCount: Int = 2) {
    guard gSwipeTap != nil else { return }
    gSwipePassthroughCount += eventCount
}

// MARK: - Swipe Tap Callback
//
// C-compatible global function, same constraint as eventTapCallback:
// the CGEvent API requires a plain function pointer.

/// CGEvent tap callback that intercepts real horizontal DockSwipe gestures
/// and replaces them with instant switches.
///
/// - Parameters:
///   - proxy: The event tap proxy (unused).
///   - type: The event type — the private gesture types arrive as raw
///     values 29/30, plus the tap-disabled housekeeping types.
///   - event: The intercepted event.
///   - userInfo: User-provided context pointer (unused).
/// - Returns: The event to pass downstream, or `nil` to swallow it.
func swipeTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                      event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)

    // Re-enable the tap if macOS disabled it, and drop any half-tracked
    // gesture: its remaining events were delivered while we were deaf,
    // so finishing it coherently is no longer possible.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        resetSwipeIntercept()
        if let tap = gSwipeTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return passthrough
    }

    let subtype = event.getIntegerValueField(kCGSEventTypeField)

    // Space Rabbit's own synthetic gestures (posted by any feature) —
    // wave them through while the pre-posted counter drains.
    if gSwipePassthroughCount > 0,
       subtype == kCGSEventDockControl || subtype == kCGSEventGesture {
        gSwipePassthroughCount -= 1
        return passthrough
    }

    // Feature gates. The tap is torn down when the feature is off, so
    // these mostly guard the "Normal" speed tick (native animation wanted
    // — let the real swipe through untouched) and toggle races.
    guard gEnabled, gTrackpadSwipeEnabled, !isNativeSwitchSpeed() else {
        gSwipeTracking = false
        gSwipeFired    = false
        return passthrough
    }

    // Horizontal dock swipes only: vertical swipes (Mission Control,
    // App Exposé) and every other gesture pass through unchanged.
    if subtype == kCGSEventDockControl,
       event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe,
       event.getIntegerValueField(kCGEventGestureSwipeMotion) == kGestureMotionHorizontal {

        let phase = event.getIntegerValueField(kCGEventGesturePhase)

        if phase == kCGSGesturePhaseBegan {
            // Mission Control slides its own carousel from this gesture —
            // see isMissionControlActive(). Stand down for the whole swipe
            // by not tracking it: every later phase then passes through
            // untouched, so the window-list lookup runs once per gesture
            // rather than for every high-frequency sample.
            guard !isMissionControlActive() else { return passthrough }

            gSwipeTracking = true
            gSwipeFired    = false
            return nil
        }

        if phase == kCGSGesturePhaseChanged, gSwipeTracking {
            // Fire once, on the first sample that reveals the direction
            if !gSwipeFired {
                let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
                if progress != 0 {
                    gSwipeFired = true
                    performSwipeSwitch(isRight: isRightSwipe(progress))
                }
            }
            return nil
        }

        if phase == kCGSGesturePhaseEnded, gSwipeTracking {
            // A very quick flick can end before any Changed sample carried
            // progress — fall back to the final velocity's sign.
            if !gSwipeFired {
                let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
                if velocity != 0 { performSwipeSwitch(isRight: isRightSwipe(velocity)) }
            }
            gSwipeTracking = false
            gSwipeFired    = false

            // macOS 27's Dock needs to see the gesture close to keep its
            // internal state consistent — pass the Ended event through
            // with its motion zeroed out so it cannot trigger a switch.
            if requiresEventAugmentation() {
                event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0)
                event.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
                event.setDoubleValueField(kCGEventGestureSwipeProgress,  value: 0)
                return passthrough
            }
            return nil
        }

        if phase == kCGSGesturePhaseCancelled {
            gSwipeTracking = false
            gSwipeFired    = false
            return nil
        }

        // Any other phase belongs to us only while tracking
        return gSwipeTracking ? nil : passthrough
    }

    // Companion generic gesture envelopes paired with a tracked dock
    // swipe — swallow them so the Dock never sees half a gesture.
    if subtype == kCGSEventGesture, gSwipeTracking { return nil }

    return passthrough
}

// MARK: - Direction & Firing

/// Whether the given progress/velocity sign means "move to the space on
/// the right". The sign convention of REAL trackpad DockSwipe events has
/// flipped across macOS releases (independently of the posting-side
/// convention documented in SpaceSwitching.swift):
///
///   - macOS ≤ 25: negative = right
///   - macOS 26:   positive = right (reported sign inverted)
///   - macOS 27+:  negative = right (inverted back, augmented path)
///
/// - Parameter sign: A non-zero swipe progress or X velocity sample.
/// - Returns: `true` when the swipe targets the next space to the right.
private func isRightSwipe(_ sign: Double) -> Bool {
    if requiresEventAugmentation() { return sign < 0 }
    if kSwipeDirectionReversed     { return sign > 0 }
    return sign < 0
}

/// Fires the instant switch replacing an intercepted swipe, mirroring the
/// keyboard path's safety rails: stand down when the space layout is
/// unknown (never post blind — issue #6), and do nothing at the edges
/// (the real gesture is already swallowed, so there is no bounce either
/// way). Velocity follows the transition-speed slider via
/// `postSwitchGesture`'s default, exactly like the keyboard feature.
///
/// - Parameter isRight: `true` to move to the next space on the right.
private func performSwipeSwitch(isRight: Bool) {
    let direction = isRight ? 1 : -1

    let (spaceIDs, currentIdx) = getSpaceList()
    guard currentIdx >= 0 else { return }

    let targetIdx = currentIdx + direction
    guard targetIdx >= 0, targetIdx < spaceIDs.count else { return }

    if postSwitchGesture(direction: direction) {
        gLastSpaceSwitchTime = Date()
        gMenu?.recordSwitch()
    }
}
