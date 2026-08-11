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
 * The overview state captured at Began then says what that direction means:
 * from the desktop, up enters Mission Control and down enters App Exposé;
 * from either overview, the opposite direction dismisses it. Directions that
 * do nothing natively, cancellations, unsupported paths, and failures replay
 * the held prefix before passing the current event through to native macOS.
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
 * Unlike the keyboard tap (installed once at startup), these taps are created
 * and torn down on demand: gesture events are high-frequency while fingers
 * touch the pad, so they only exist while either feature is active.
 *
 * There are two of them, split by event type for the same reason. Every event
 * a `.defaultTap` subscribes to costs a synchronous round-trip through this
 * process before macOS may deliver it, so the split keeps the high-rate type
 * off the tap while there is nothing to intercept:
 *
 *   - DockControl (30) — the events that actually carry a DockSwipe, and the
 *     only ones that can *open* a gesture. Rare (a couple of hundred per
 *     swipe, none at all otherwise), so this tap stays enabled throughout.
 *   - Gesture (29) — the generic envelopes, emitted continuously for any
 *     finger on the trackpad, including plain cursor movement. They are only
 *     ever acted on while a gesture is already claimed, so this tap is enabled
 *     on Began and disabled again as soon as tracking ends.
 */

import CoreGraphics
import Foundation

// MARK: - Constants

// Both motion values are read here and written by the posting code in
// SpaceSwitching.swift, so they are declared once, module-wide.

/// Value of `kCGEventGestureSwipeMotion` identifying a horizontal swipe.
let kGestureMotionHorizontal: Int64 = 1

/// Value identifying the vertical DockSwipe family used by Mission Control
/// and App Exposé.
let kGestureMotionVertical: Int64 = 2

/// Smallest `kCGEventGestureSwipeProgress` magnitude whose sign is trusted to
/// mean the user's intended direction.
///
/// Progress is reported as the gesture's absolute travel, so the samples right
/// after touchdown are near zero and their sign is whichever way the fingers
/// happened to drift first. Committing on the first non-zero sample therefore
/// reads a wobble as intent: on the vertical path a downward swipe whose
/// fingers rocked up by a thousandth resolves as Mission Control entry instead
/// of App Exposé (issue #43), and on the horizontal path the same wobble
/// switches to the wrong space. Both are irreversible once posted, because the
/// physical gesture has already been swallowed.
///
/// A real swipe crosses this in a few milliseconds of finger travel, so the
/// wait is not perceptible; a gesture that never crosses it stands down and is
/// replayed to macOS, which is the correct answer for a gesture that carried no
/// direction.
private let kGestureDirectionThreshold: Double = 0.05

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
        // Two taps rather than one with a combined mask: DockControl is rare
        // enough to listen for continuously, while the envelope type fires on
        // every trackpad touch sample and is only ever acted on mid-gesture.
        guard let dockTap = makeGestureTap(subtype: kCGSEventDockControl) else {
            fputs("Space Rabbit: failed to create swipe intercept tap\n", stderr)
            return
        }
        guard let envelopeTap = makeGestureTap(subtype: kCGSEventGesture) else {
            fputs("Space Rabbit: failed to create gesture envelope tap\n", stderr)
            destroyGestureTap(dockTap.tap, source: dockTap.source)
            return
        }

        CGEvent.tapEnable(tap: dockTap.tap, enable: true)
        // Left disabled until a gesture is claimed.
        CGEvent.tapEnable(tap: envelopeTap.tap, enable: false)

        gSwipeTap                   = dockTap.tap
        gSwipeTapSource             = dockTap.source
        gGestureEnvelopeTap         = envelopeTap.tap
        gGestureEnvelopeTapSource   = envelopeTap.source
        gGestureEnvelopeTapEnabled  = false
        resetSwipeIntercept()
    } else if !shouldRun, let tap = gSwipeTap {
        // A held/claimed Mission Control gesture must reach its terminal
        // event before the tap disappears, or Dock would receive a partial
        // physical stream. The next callback finishes native replay or
        // swallowing and schedules this lifecycle check again.
        if gMissionControlSwipeTracking || !gPendingMissionControlEvents.isEmpty {
            return
        }

        destroyGestureTap(tap, source: gSwipeTapSource)
        destroyGestureTap(gGestureEnvelopeTap, source: gGestureEnvelopeTapSource)

        gSwipeTap                  = nil
        gSwipeTapSource            = nil
        gGestureEnvelopeTap        = nil
        gGestureEnvelopeTapSource  = nil
        gGestureEnvelopeTapEnabled = false
        resetSwipeIntercept()
    }
}

/// Creates one session tap listening for a single private gesture event type.
///
/// - Parameter subtype: `kCGSEventGesture` or `kCGSEventDockControl` — which
///   double as the `CGEventType` raw values these events arrive as.
/// - Returns: The tap and its run loop source, already added to the main run
///   loop but not yet enabled, or `nil` if the tap could not be created.
private func makeGestureTap(subtype: Int64) -> (tap: CFMachPort, source: CFRunLoopSource)? {
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << UInt64(subtype)),
        callback: swipeTapCallback,
        userInfo: nil
    ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
        return nil
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    return (tap, source)
}

/// Disables a gesture tap and unhooks its source from the run loop.
///
/// - Parameters:
///   - tap: The tap to disable, if it exists.
///   - source: Its run loop source, if it exists.
private func destroyGestureTap(_ tap: CFMachPort?, source: CFRunLoopSource?) {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
}

/// Enables the envelope tap for exactly as long as a gesture is claimed, and
/// disables it again the moment nothing is being tracked.
///
/// Called from a `defer` covering every exit of `swipeTapCallback`, so the
/// enabled state always matches the tracking state no matter which branch
/// returned. Claiming always begins on a DockControl Began, which the
/// always-on tap sees; measured on macOS 26, that Began's own companion
/// envelope arrives just *before* it and is therefore already past — but the
/// interceptor never swallowed that one either (nothing is tracked yet when it
/// arrives), and the next envelope is a full sample period later.
private func syncGestureEnvelopeTap() {
    guard let tap = gGestureEnvelopeTap else { return }

    let shouldListen = gSwipeTracking
        || gMissionControlSwipeTracking
        || !gPendingMissionControlEvents.isEmpty
    guard shouldListen != gGestureEnvelopeTapEnabled else { return }

    CGEvent.tapEnable(tap: tap, enable: shouldListen)
    gGestureEnvelopeTapEnabled = shouldListen
}

/// Clears all per-gesture tracking state. Called whenever the tap's
/// continuity breaks (created, torn down, or re-enabled after a system
/// disable) — stale state from before the break must not leak into the
/// next gesture.
func resetSwipeIntercept() {
    gSwipeTracking               = false
    gSwipeFired                  = false
    gSwipeInOverview             = false
    gMissionControlSwipeTracking = false
    gPendingMissionControlEvents.removeAll(keepingCapacity: true)
    gPendingMissionControlOverviewState = nil
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
    gPendingMissionControlOverviewState = nil
}

/// Rechecks whether the shared tap is still needed after a deferred Mission
/// Control gesture finishes.
///
/// `updateSwipeTap()` is asked unconditionally rather than re-deriving the
/// teardown condition here: it already no-ops when the tap matches the
/// current state, and a second copy of that condition would be free to
/// drift out of sync with the real one and strand the tap.
private func finishMissionControlInterception() {
    gMissionControlSwipeTracking = false
    gPendingMissionControlOverviewState = nil
    DispatchQueue.main.async { updateSwipeTap() }
}

/// Resolves a physical vertical sign against the overview state that was
/// captured at Began.
///
/// Both vertical overviews the Dock drives from this gesture are owned, each
/// in the one direction that means something on screen:
///
///   - desktop → up enters Mission Control, down enters App Exposé
///   - Mission Control → down dismisses it
///   - App Exposé → up dismisses it
///
/// The remaining two combinations do nothing natively (there is no "further
/// up" from Mission Control, nor "further down" from App Exposé), so they stay
/// native rather than being replaced with a transition macOS would not have
/// performed.
///
/// Physical vertical DockSwipes use screen-coordinate signs on macOS 26:
/// finger-up is negative and finger-down is positive. Synthetic vertical
/// posting uses the opposite convention, so this conversion must stay separate
/// from `postMissionControlTransition`'s signed output.
private func pendingMissionControlDirection(forPhysicalSign sign: Double) -> Int? {
    guard sign != 0,
          let overviewState = gPendingMissionControlOverviewState
    else { return nil }

    let direction = sign < 0 ? 1 : -1

    switch overviewState {
    case .desktop:        return direction
    case .missionControl: return direction < 0 ? direction : nil
    case .appExpose:      return direction > 0 ? direction : nil
    }
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

/// Terminal handling for a claimed vertical gesture on macOS 27+: Dock still
/// needs to see the physical Ended, with the motion stripped from both the
/// ordinary fields and the mirrored field-4205 payload.
///
/// Should the payload rebuild fail, the ordinary fields are zeroed in place
/// and the event goes through regardless — the same contract the horizontal
/// interceptor has always used. Swallowing the Ended outright would leave
/// Dock's gesture state open, which is the worse of the two failures.
///
/// - Parameter event: The intercepted terminal DockSwipe event.
/// - Returns: The event Dock should receive.
private func missionControlCleanupResult(for event: CGEvent) -> Unmanaged<CGEvent>? {
    if let cleanup = makeMissionControlCleanupEvent(from: event) {
        return Unmanaged.passRetained(cleanup)
    }

    clearGestureMotion(event)
    return Unmanaged.passUnretained(event)
}

// MARK: - Synthetic Event Marking

/// Stamped into `.eventSourceUserData` on every gesture event Space Rabbit
/// posts, so the swipe tap can recognise its own events on the way back in.
/// The field survives the round trip through the session tap, but not
/// `CGEventCreateFromData`; augmented events are therefore stamped after their
/// field-4205 flatten/rebuild.
private let kSyntheticGestureMarker: Int64 = 0x5350_4152  // 'SPAR'

/// Marks an event as posted by Space Rabbit, so the swipe-intercept tap
/// passes it through instead of re-intercepting it (which would loop:
/// intercept → post → intercept → …).
///
/// Called by the gesture posting code in SpaceSwitching.swift on every final
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

    // The envelope tap is only worth its wakeups while a gesture is claimed,
    // and every branch below can start or end a claim.
    defer { syncGestureEnvelopeTap() }

    // Re-enable the tap if macOS disabled it, and drop any half-tracked
    // gesture: its remaining events were delivered while we were deaf,
    // so finishing it coherently is no longer possible.
    //
    // The notification does not say which of the two taps was disabled, so the
    // always-on one is re-enabled unconditionally (a redundant enable is
    // harmless) and the envelope tap is left to the `defer` above, which now
    // resolves to "disabled" because the reset dropped every claim.
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
                return missionControlCleanupResult(for: event)
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
    // only after positively identifying which overview state is on screen,
    // before Dock can animate. Changed then resolves the direction into a
    // Mission Control or App Exposé transition, or stands the gesture down.
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

            // Every state this resolves to is drivable in at least one
            // direction; Show Desktop and unreadable private state come back
            // nil and stay native. Which direction is owned is settled later,
            // once Changed supplies one.
            guard let overviewState = currentDockOverviewState(),
                  let beganCopy = event.copy() else { return passthrough }

            gPendingMissionControlEvents = [beganCopy]
            gPendingMissionControlOverviewState = overviewState
            return nil
        }

        if !gPendingMissionControlEvents.isEmpty {
            let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)

            if phase == kCGSGesturePhaseChanged,
               abs(progress) >= kGestureDirectionThreshold {
                if let direction = pendingMissionControlDirection(forPhysicalSign: progress),
                   postMissionControlTransition(proxy: proxy,
                                                direction: direction) {
                    gPendingMissionControlEvents.removeAll(keepingCapacity: true)
                    gPendingMissionControlOverviewState = nil
                    gMissionControlSwipeTracking = true
                    gMenu?.recordSwitch()
                    return nil
                }

                replayPendingMissionControlEvents(proxy: proxy)
                return passthrough
            }

            if phase == kCGSGesturePhaseEnded {
                // Travel that never crossed the trust threshold says nothing
                // about intent, so a flick short enough to end there falls back
                // to its terminal velocity exactly as one carrying no progress
                // at all does.
                let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
                let sign = abs(progress) >= kGestureDirectionThreshold
                    ? progress : velocity

                if let direction = pendingMissionControlDirection(forPhysicalSign: sign),
                   postMissionControlTransition(proxy: proxy,
                                                direction: direction) {
                    gPendingMissionControlEvents.removeAll(keepingCapacity: true)
                    finishMissionControlInterception()
                    gMenu?.recordSwitch()
                    if requiresEventAugmentation() {
                        return missionControlCleanupResult(for: event)
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

    // Horizontal feature gates. Two independent features reach this path: the
    // trackpad-Space toggle owns swipes on the desktop, and the Mission Control
    // toggle additionally owns the ones that navigate its overview's carousel.
    // Both follow the shared transition-speed slider.
    let desktopSwipeEnabled  = gTrackpadSwipeEnabled && !isNativeSwitchSpeed()
    let overviewSwipeEnabled = gInstantMissionControlEnabled
        && !isNativeSwitchSpeed()
        && supportsInstantMissionControlInterception()

    guard desktopSwipeEnabled || overviewSwipeEnabled else {
        gSwipeTracking   = false
        gSwipeFired      = false
        gSwipeInOverview = false
        return passthrough
    }

    // Horizontal dock swipes only; unclaimed vertical gestures and every
    // other gesture pass through unchanged.
    if subtype == kCGSEventDockControl,
       event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe,
       event.getIntegerValueField(kCGEventGestureSwipeMotion) == kGestureMotionHorizontal {

        let phase = event.getIntegerValueField(kCGEventGesturePhase)

        if phase == kCGSGesturePhaseBegan {
            // Which recipe replaces this swipe depends on what is on screen,
            // and the answer is settled once here: every later phase then
            // follows gSwipeTracking, so the window-list lookup runs once per
            // gesture rather than for every high-frequency sample.
            //
            // Off the desktop this stays the cheap layer-18 test, whose
            // fail-open answer keeps the long-standing desktop path working
            // when the window list cannot be read. Only once an overview is
            // known to be up is the exact state resolved: Mission Control
            // navigates spaces with this gesture and can be driven, while App
            // Exposé, Show Desktop and unreadable private state stay native.
            if isMissionControlActive() {
                guard overviewSwipeEnabled,
                      currentDockOverviewState() == .missionControl
                else { return passthrough }

                gSwipeInOverview = true
            } else {
                guard desktopSwipeEnabled else { return passthrough }

                gSwipeInOverview = false
            }

            gSwipeTracking = true
            gSwipeFired    = false
            return nil
        }

        if phase == kCGSGesturePhaseChanged, gSwipeTracking {
            // Fire once, on the first sample whose travel is far enough for
            // its sign to be the user's intent rather than touchdown wobble.
            if !gSwipeFired {
                let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
                if abs(progress) >= kGestureDirectionThreshold {
                    gSwipeFired = true
                    performSwipeSwitch(proxy: proxy, isRight: isRightSwipe(progress))
                }
            }
            return nil
        }

        if phase == kCGSGesturePhaseEnded, gSwipeTracking {
            // A very quick flick can end before any Changed sample carried
            // progress — fall back to the final velocity's sign.
            if !gSwipeFired {
                let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
                if velocity != 0 {
                    performSwipeSwitch(proxy: proxy, isRight: isRightSwipe(velocity))
                }
            }
            gSwipeTracking   = false
            gSwipeFired      = false
            gSwipeInOverview = false

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
            gSwipeTracking   = false
            gSwipeFired      = false
            gSwipeInOverview = false
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
/// the right".
///
/// Real trackpad DockSwipe events report horizontal progress/velocity with
/// positive = right on every macOS release this app runs on. macOS 27
/// (including build 26A5388g) inverts only the POSTING-side convention
/// (`makeAugmentedDockEvent` in SpaceSwitching.swift): the augmented
/// synthetic events the Dock accepts carry negative signs for rightward
/// movement. That inversion does NOT extend to real events — assuming it
/// does makes `isRightSwipe` read every physical swipe backwards, so a
/// left-to-right swipe switches to the previous space (issue #40).
///
/// The "Natural scrolling" setting needs no handling here: the window
/// server already flips the reported sign when the user turns it off, so
/// the mapping from sign to space is unconditional. Correcting for the
/// setting on top of that double-flips it — measured on macOS 26, natural
/// scrolling OFF: a left-to-right swipe reports progress +0.045 and must
/// move right, same rule as ON.
///
/// - Parameter sign: A non-zero swipe progress or X velocity sample.
/// - Returns: `true` when the swipe targets the next space to the right.
private func isRightSwipe(_ sign: Double) -> Bool {
    sign > 0
}

/// Fires the switch replacing an intercepted swipe, mirroring the keyboard
/// path's safety rails: stand down when the space layout is unknown (never
/// post blind — issue #6), and do nothing at the edges (the real gesture is
/// already swallowed, so there is no bounce either way). Speed follows the
/// transition-speed slider on both recipes, exactly like the keyboard feature.
///
/// A gesture that began inside the Mission Control overview is replaced with
/// the segmented carousel stream instead of the desktop's boundary jump, which
/// the overview cannot act on (issue #16).
///
/// - Parameters:
///   - proxy: The active swipe-intercept tap proxy, used by the overview
///     recipe to inject its replacement gesture in order.
///   - isRight: `true` to move to the next space on the right.
private func performSwipeSwitch(proxy: CGEventTapProxy, isRight: Bool) {
    let direction = isRight ? 1 : -1

    let (spaceIDs, currentIdx) = getSpaceList()
    guard currentIdx >= 0 else { return }

    let targetIdx = currentIdx + direction
    guard targetIdx >= 0, targetIdx < spaceIDs.count else { return }

    let posted = gSwipeInOverview
        ? postOverviewSpaceSwitch(proxy: proxy, direction: direction)
        : postSwitchGesture(direction: direction)

    if posted {
        gLastSpaceSwitchTime = Date()
        gMenu?.recordSwitch()
    }
}
