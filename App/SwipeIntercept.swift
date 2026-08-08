/*
 * SwipeIntercept.swift — Instant trackpad gesture interception
 *
 * Controls the transition speed of real horizontal Space swipes and both
 * Mission Control entry and dismissal gestures.
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
 * Horizontal direction follows the existing flow. A vertical Began does not
 * carry direction, so it is copied and held until Changed supplies progress.
 * The overview state captured at Began disambiguates desktop→up (Mission
 * Control entry) from overview→down (dismissal). App Exposé entry, opposite
 * directions, cancellations, unsupported paths, and failures replay the held
 * prefix before passing the current event through to native macOS.
 *
 * Because Space Rabbit's own synthetic gestures are posted into the same
 * session tap, they would loop right back into this tap. Every event we
 * post is stamped with `kSyntheticGestureMarker` in its source user-data
 * field and waved straight through on the way back in.
 *
 * (joshuarli/iss, from which this interception scheme is ported, counts
 * pending synthetic events instead. That cannot work here: the real
 * gesture's own Changed samples match the same event subtypes, so they
 * drain the counter before our synthetic events arrive, and the leftover
 * synthetic Ended is then read as a real swipe — firing a second switch
 * from its ±kInstantSwitchVelocity sign.)
 *
 * Unlike the keyboard tap (installed once at startup), this tap is created
 * and torn down on demand: gesture events are high-frequency while fingers
 * touch the pad, so the tap only exists while either feature is active.
 */

import CoreGraphics
import Foundation

// MARK: - Constants

/// Value of `kCGEventGestureSwipeMotion` identifying a horizontal swipe.
private let kGestureMotionHorizontal: Int64 = 1

/// Value identifying the vertical DockSwipe family used by Mission Control
/// and App Exposé.
private let kGestureMotionVertical: Int64 = 2

// MARK: - Tap Lifecycle

/// Creates or tears down the swipe-intercept tap to match the current
/// feature state (`gEnabled` and either gesture feature enabled).
///
/// Called at startup and from every place that flips either toggle (the
/// menu bar dropdown, the master switch, and the settings window). Safe to
/// call redundantly — it no-ops when the tap already matches the state.
func updateSwipeTap() {
    let missionControlEnabled = gInstantMissionControlEnabled
        && !isNativeSwitchSpeed()
        && supportsInstantMissionControlInterception()
    let shouldRun = gEnabled
        && (gTrackpadSwipeEnabled || missionControlEnabled)

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
        // A held/claimed Mission Control gesture must reach its terminal
        // event before the tap disappears, or Dock would receive a partial
        // physical stream. The next callback finishes native replay or
        // swallowing and schedules this lifecycle check again.
        if gMissionControlSwipeTracking || !gPendingMissionControlEvents.isEmpty {
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = gSwipeTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        gSwipeTap       = nil
        gSwipeTapSource = nil
        resetSwipeIntercept()
    }
}

/// Clears all per-gesture tracking state. Called whenever the tap's
/// continuity breaks (created, torn down, or re-enabled after a system
/// disable) — stale state from before the break must not leak into the
/// next gesture.
func resetSwipeIntercept() {
    gSwipeTracking               = false
    gSwipeFired                  = false
    gMissionControlSwipeTracking = false
    gPendingMissionControlEvents.removeAll(keepingCapacity: true)
    gPendingMissionControlStartedInOverview = nil
}

/// Reinjects a held physical vertical-gesture prefix immediately after this
/// tap. The callback then returns the current event normally, restoring the
/// native stream in order when Space Rabbit stands down after Began.
///
/// - Parameter proxy: The active swipe-intercept tap proxy.
private func replayPendingMissionControlEvents(proxy: CGEventTapProxy) {
    for pendingEvent in gPendingMissionControlEvents {
        pendingEvent.tapPostEvent(proxy)
    }
    gPendingMissionControlEvents.removeAll(keepingCapacity: true)
    gPendingMissionControlStartedInOverview = nil
}

/// Rechecks whether the shared tap is still needed after a deferred Mission
/// Control gesture finishes.
private func finishMissionControlInterception() {
    gMissionControlSwipeTracking = false
    gPendingMissionControlStartedInOverview = nil
    if !gEnabled || (!gTrackpadSwipeEnabled
        && (!gInstantMissionControlEnabled || isNativeSwitchSpeed())) {
        DispatchQueue.main.async { updateSwipeTap() }
    }
}

/// Resolves a non-zero physical vertical sign against the overview state that
/// was captured at Began. Only desktop→up and overview→down are owned; App
/// Exposé entry and any opposite-direction gesture remain native.
///
/// Physical vertical DockSwipes use screen-coordinate signs on macOS 26:
/// finger-up is negative and finger-down is positive. Synthetic Mission
/// Control posting uses the opposite convention, so this conversion must stay
/// separate from `postMissionControlTransition`'s signed output.
private func pendingMissionControlDirection(forPhysicalSign sign: Double) -> Int? {
    guard sign != 0,
          let startedInOverview = gPendingMissionControlStartedInOverview
    else { return nil }

    let direction = sign < 0 ? 1 : -1
    let isDismissal = direction < 0
    return startedInOverview == isDismissal ? direction : nil
}

/// Removes every ordinary progress/velocity component from a physical Ended
/// event before it is passed to Dock as macOS 27 gesture cleanup.
///
/// - Parameter event: The intercepted terminal DockSwipe event.
private func clearGestureMotion(_ event: CGEvent) {
    event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0)
    event.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
    event.setDoubleValueField(kCGEventGestureSwipeProgress, value: 0)
}

// MARK: - Synthetic Event Marking

/// Stamped into `.eventSourceUserData` on every gesture event Space Rabbit
/// posts, so the swipe tap can recognise its own events on the way back in.
/// The field is carried by the event record and survives the round trip
/// through the session tap (including the macOS 27+ flatten/rebuild in
/// `augmentDockSwipeEvent`, which is applied after the stamp).
private let kSyntheticGestureMarker: Int64 = 0x5350_4152  // 'SPAR'

/// Marks an event as posted by Space Rabbit, so the swipe-intercept tap
/// passes it through instead of re-intercepting it (which would loop:
/// intercept → post → intercept → …).
///
/// Called by the gesture posting code in SpaceSwitching.swift on every
/// event before it goes out — unconditionally, whether or not the tap is
/// currently installed, so a tap installed mid-sequence still recognises
/// events already in flight.
///
/// - Parameter event: The gesture or dock-control event about to be posted.
func markSyntheticGesture(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: kSyntheticGestureMarker)
}

/// Whether an incoming event is one Space Rabbit posted itself.
///
/// - Parameter event: The event delivered to the swipe tap.
/// - Returns: `true` when the event carries `kSyntheticGestureMarker`.
private func isSyntheticGesture(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == kSyntheticGestureMarker
}

// MARK: - Swipe Tap Callback
//
// C-compatible global function, same constraint as eventTapCallback:
// the CGEvent API requires a plain function pointer.

/// CGEvent tap callback that replaces supported horizontal Space swipes and
/// Mission Control entry/dismissal gestures with controlled DockSwipes.
///
/// - Parameters:
///   - proxy: The event tap proxy used for native replay and vertical
///     replacement events.
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
        replayPendingMissionControlEvents(proxy: proxy)
        resetSwipeIntercept()
        if let tap = gSwipeTap { CGEvent.tapEnable(tap: tap, enable: true) }
        DispatchQueue.main.async { updateSwipeTap() }
        return passthrough
    }

    // Space Rabbit's own synthetic gestures (posted by any feature) land
    // in this same session tap — wave them straight through, or they would
    // be read as real swipes and fire a switch of their own.
    if isSyntheticGesture(event) { return passthrough }

    let subtype = event.getIntegerValueField(kCGSEventTypeField)

    // Finish a claimed vertical stream even if a toggle changed mid-gesture.
    // On macOS 27+, mirror the established horizontal cleanup contract: Dock
    // receives the physical Ended with all motion zeroed so its state closes
    // without starting another transition.
    if gMissionControlSwipeTracking {
        if subtype == kCGSEventDockControl {
            let phase = event.getIntegerValueField(kCGEventGesturePhase)
            if phase == kCGSGesturePhaseEnded || phase == kCGSGesturePhaseCancelled {
                finishMissionControlInterception()
            }
            if phase == kCGSGesturePhaseEnded, requiresEventAugmentation() {
                clearGestureMotion(event)
                return passthrough
            }
            return nil
        }
        if subtype == kCGSEventGesture { return nil }
    }

    // The tap is normally torn down while the master switch is off; this
    // covers a toggle racing with event delivery. Replay an unresolved Began
    // before returning the current event so native macOS sees a full stream.
    guard gEnabled else {
        replayPendingMissionControlEvents(proxy: proxy)
        resetSwipeIntercept()
        DispatchQueue.main.async { updateSwipeTap() }
        return passthrough
    }

    // If the option changed while Began was held, restore the prefix and let
    // the current event continue natively before the deferred tap teardown.
    if (!gInstantMissionControlEnabled || isNativeSwitchSpeed()),
       !gPendingMissionControlEvents.isEmpty {
        replayPendingMissionControlEvents(proxy: proxy)
        finishMissionControlInterception()
    }

    // Generic envelopes paired with an unresolved vertical prefix are held in
    // arrival order. Failed copies immediately restore native delivery.
    if !gPendingMissionControlEvents.isEmpty, subtype == kCGSEventGesture {
        guard let envelopeCopy = event.copy() else {
            replayPendingMissionControlEvents(proxy: proxy)
            finishMissionControlInterception()
            return passthrough
        }
        gPendingMissionControlEvents.append(envelopeCopy)
        return nil
    }

    // Vertical Began is directionless on supported macOS releases. Hold it
    // only after positively identifying desktop versus overview state, before
    // Dock can animate. Changed resolves desktop→up as entry and overview→down
    // as dismissal; App Exposé entry and opposite directions remain native.
    if gInstantMissionControlEnabled,
       !isNativeSwitchSpeed(),
       supportsInstantMissionControlInterception(),
       subtype == kCGSEventDockControl,
       event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe,
       event.getIntegerValueField(kCGEventGestureSwipeMotion) == kGestureMotionVertical {
        let phase = event.getIntegerValueField(kCGEventGesturePhase)

        if phase == kCGSGesturePhaseBegan {
            if !gPendingMissionControlEvents.isEmpty {
                replayPendingMissionControlEvents(proxy: proxy)
            }

            guard let startedInOverview = missionControlOverviewState(),
                  let beganCopy = event.copy() else { return passthrough }

            gPendingMissionControlEvents = [beganCopy]
            gPendingMissionControlStartedInOverview = startedInOverview
            return nil
        }

        if !gPendingMissionControlEvents.isEmpty {
            let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)

            if phase == kCGSGesturePhaseChanged, progress != 0 {
                if let direction = pendingMissionControlDirection(forPhysicalSign: progress),
                   postMissionControlTransition(proxy: proxy,
                                                direction: direction) {
                    gPendingMissionControlEvents.removeAll(keepingCapacity: true)
                    gPendingMissionControlStartedInOverview = nil
                    gMissionControlSwipeTracking = true
                    return nil
                }

                replayPendingMissionControlEvents(proxy: proxy)
                return passthrough
            }

            if phase == kCGSGesturePhaseEnded {
                let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
                let sign = progress != 0 ? progress : velocity

                if let direction = pendingMissionControlDirection(forPhysicalSign: sign),
                   postMissionControlTransition(proxy: proxy,
                                                direction: direction) {
                    gPendingMissionControlEvents.removeAll(keepingCapacity: true)
                    finishMissionControlInterception()
                    if requiresEventAugmentation() {
                        clearGestureMotion(event)
                        return passthrough
                    }
                    return nil
                }

                replayPendingMissionControlEvents(proxy: proxy)
                finishMissionControlInterception()
                return passthrough
            }

            if phase == kCGSGesturePhaseCancelled {
                replayPendingMissionControlEvents(proxy: proxy)
                finishMissionControlInterception()
                return passthrough
            }

            // Preserve any still-ambiguous DockControl sample for native
            // replay rather than allowing a partial physical stream.
            guard let eventCopy = event.copy() else {
                replayPendingMissionControlEvents(proxy: proxy)
                finishMissionControlInterception()
                return passthrough
            }
            gPendingMissionControlEvents.append(eventCopy)
            return nil
        }
    }

    // Horizontal feature gates. Mission Control is independent from the
    // trackpad-Space toggle and was already handled above with the shared
    // transition-speed slider.
    guard gTrackpadSwipeEnabled, !isNativeSwitchSpeed() else {
        gSwipeTracking = false
        gSwipeFired    = false
        return passthrough
    }

    // Horizontal dock swipes only; unclaimed vertical gestures and every
    // other gesture pass through unchanged.
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
                clearGestureMotion(event)
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
/// the right". The raw sign convention of REAL trackpad DockSwipe events
/// has flipped across macOS releases (independently of the posting-side
/// convention documented in SpaceSwitching.swift):
///
///   - macOS ≤ 26: positive = right
///   - macOS 27+:  negative = right (inverted on the augmented path)
///
/// The "Natural scrolling" setting needs no handling here: the window
/// server already flips the reported sign when the user turns it off, so
/// the rows above hold in both modes and the mapping from sign to space is
/// unconditional. Correcting for the setting on top of that double-flips
/// it — measured on macOS 26, natural scrolling OFF: a left-to-right swipe
/// reports progress +0.045 and must move right, same rule as ON.
///
/// - Parameter sign: A non-zero swipe progress or X velocity sample.
/// - Returns: `true` when the swipe targets the next space to the right.
private func isRightSwipe(_ sign: Double) -> Bool {
    if requiresEventAugmentation() { return sign < 0 }
    return sign > 0
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
