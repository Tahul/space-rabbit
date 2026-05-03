/*
 * SpaceSwitching.swift — Space queries, gesture posting, and navigation
 *
 * This file contains the core mechanics of Space Rabbit:
 *
 *   1. Querying the current space layout across all displays
 *   2. Posting synthetic DockSwipe gestures that trigger instant switching
 *   3. Finding which space an app's windows live on
 *   4. Computing the shortest path to a target space and switching
 *
 * The synthetic gesture technique works because macOS's Dock process
 * handles high-velocity DockSwipe events by switching spaces immediately
 * without playing the slide animation. We exploit this by posting
 * a Began+Ended gesture pair with extreme velocity values.
 */

import CoreGraphics
import CoreFoundation
import Foundation

// MARK: - Constants

/// Space type bitmask passed to `SLSCopySpacesForWindows`.
/// Value 7 means "all space types" (user spaces, fullscreen, etc.).
/// This is an undocumented constant from the private SkyLight framework.
private let kSLSSpaceTypeAll: Int32 = 7

/// Absolute swipe progress value that tells the Dock the swipe is
/// fully committed (i.e. the user has dragged all the way through).
/// Positive = right, negative = left.
private let kInstantSwitchProgress: Double = 2.0

/// Absolute swipe velocity that exceeds the Dock's threshold for
/// triggering an instant (non-animated) space switch.
/// Positive = right, negative = left.
private let kInstantSwitchVelocity: Double = 400.0

// MARK: - Space Layout Queries

/// Returns the space IDs for the display that contains the active space,
/// along with the index of the active space within that list.
///
/// This is used by the event tap to check whether a left/right switch
/// is possible (i.e., we're not already at the edge).
///
/// - Returns: A tuple of (space IDs on the active display, index of current space).
///            Returns `([], -1)` if the space layout cannot be determined.
func getSpaceList() -> (ids: [CGSSpaceID], currentIdx: Int) {
    guard let mainConn    = cgsMainConnection,
          let getActive   = cgsGetActiveSpace,
          let getDisplays = cgsCopyDisplaySpaces else { return ([], -1) }

    let cid = mainConn()
    guard cid != 0 else { return ([], -1) }

    let active = getActive(cid)
    guard active != 0 else { return ([], -1) }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return ([], -1) }

    // Walk each display to find the one containing the active space.
    // Multi-monitor setups have one entry per display; we only care
    // about the display whose "Current Space" matches the active space.
    for display in displays {
        guard let currentSpaceDict = display["Current Space"] as? [String: Any],
              let currentSpaceID   = (currentSpaceDict["id64"] as? NSNumber)?.uint64Value,
              currentSpaceID == active,
              let spaces           = display["Spaces"] as? [[String: Any]]
        else { continue }

        var ids        = [CGSSpaceID]()
        var currentIdx = -1

        for space in spaces {
            guard let sid = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            if sid == active { currentIdx = ids.count }
            ids.append(sid)
        }

        return (ids, currentIdx)
    }

    return ([], -1)
}

/// Returns the "current space" ID for every connected display.
///
/// Used by auto-follow to determine whether an app is already visible
/// on any display (in which case we don't need to switch).
///
/// - Returns: An array of space IDs, one per display that has an active space.
private func getAllCurrentSpaces() -> [CGSSpaceID] {
    guard let mainConn    = cgsMainConnection,
          let getDisplays = cgsCopyDisplaySpaces else { return [] }

    let cid = mainConn()
    guard cid != 0 else { return [] }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return [] }

    return displays.compactMap { display -> CGSSpaceID? in
        guard let currentSpaceDict = display["Current Space"] as? [String: Any],
              let sid              = (currentSpaceDict["id64"] as? NSNumber)?.uint64Value,
              sid != 0 else { return nil }
        return sid
    }
}

// MARK: - Window-to-Space Mapping

/// Returns the space IDs of all normal, on-screen windows belonging
/// to the given process, in front-to-back order.
///
/// "Normal" means layer 0 (excludes menus, tooltips, status items, etc.)
/// and on-screen (excludes hidden or minimized windows).
///
/// Each window is mapped to its space via the private `SLSCopySpacesForWindows`
/// API. Windows that cannot be resolved to a valid space are skipped.
///
/// - Parameter pid: The Unix process ID of the target application.
/// - Returns: An ordered array of space IDs for the process's visible windows.
private func visibleWindowSpaces(for pid: pid_t) -> [CGSSpaceID] {
    guard let mainConn  = cgsMainConnection,
          let spacesFor = slsCopySpacesForWindows else { return [] }

    let cid = mainConn()
    guard cid != 0 else { return [] }

    guard let windowList = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]]
    else { return [] }

    var result = [CGSSpaceID]()

    for window in windowList {
        // Only consider windows owned by the target process
        guard (window["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid else { continue }

        // Skip non-normal windows (menus, tooltips, status items, overlays)
        if let layer = (window["kCGWindowLayer"] as? NSNumber)?.int32Value,
           layer != 0 { continue }

        // Skip offscreen/hidden windows (minimized, behind other spaces)
        if let onscreen = (window["kCGWindowIsOnscreen"] as? NSNumber)?.int32Value,
           onscreen == 0 { continue }

        guard let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        else { continue }

        // Ask the private API which space this window lives on
        let windowIDArray = [NSNumber(value: windowID)] as CFArray
        guard let spaces = spacesFor(cid, kSLSSpaceTypeAll, windowIDArray)?
                .takeRetainedValue() as? [NSNumber],
              let spaceID = spaces.first?.uint64Value,
              spaceID != 0
        else { continue }

        result.append(spaceID)
    }

    return result
}

// MARK: - Process Space Lookup

/// Finds the space that should be switched to when activating the given process.
///
/// Walks the process's visible windows (in front-to-back order) and determines
/// whether any of them are already on a currently-visible display. If so, no
/// switch is needed and this returns 0. Otherwise, it returns the space of the
/// frontmost off-screen window.
///
/// - Parameter pid: The Unix process ID of the app to locate.
/// - Returns: The space ID to switch to, or `0` if the app is already
///            accessible on a visible space (no switch needed).
func findSpaceForPid(_ pid: pid_t) -> CGSSpaceID {
    let currentSpaces = getAllCurrentSpaces()
    let windowSpaces  = visibleWindowSpaces(for: pid)

    // If any window is already on a visible space, the app is reachable.
    // Don't follow — this prevents chasing a second window on a different
    // space when the user is already on the right one.
    for sid in windowSpaces {
        if currentSpaces.contains(sid) { return 0 }
    }

    // Return the frontmost off-screen window's space (first in the list,
    // since CGWindowList returns windows in front-to-back order)
    return windowSpaces.first ?? 0
}

/// Returns `true` if every normal, on-screen window of the process lives
/// on `targetSpace` — meaning no window is on any other space.
///
/// This must be called at notification time (before `switchToSpace`), while
/// the CGS state is still fresh. The result tells the caller whether it is
/// safe to call `activate(.activateAllWindows)` after switching: that flag
/// asks macOS to raise every window of the app, which triggers a native
/// cross-space switch for any window on a different space. When this returns
/// `false` (windows on multiple spaces), the caller should fall back to
/// `activate([])` to stay on the space we just switched to.
///
/// - Parameters:
///   - pid: The Unix process ID of the app to check.
///   - targetSpace: The space that all windows should be on.
/// - Returns: `true` if all visible windows are confined to `targetSpace`.
func appWindowsConfinedToSpace(_ pid: pid_t, _ targetSpace: CGSSpaceID) -> Bool {
    return visibleWindowSpaces(for: pid).allSatisfy { $0 == targetSpace }
}

/// Switches to the space identified by `targetSpace` on whichever display
/// contains it.
///
/// Walks the space layout for all displays, finds which one contains both
/// the current and target spaces, computes the minimum number of directional
/// steps, and posts that many gesture pairs.
///
/// - Parameter targetSpace: The space ID to switch to.
func switchToSpace(_ targetSpace: CGSSpaceID) {
    guard let mainConn    = cgsMainConnection,
          let getDisplays = cgsCopyDisplaySpaces else { return }

    let cid = mainConn()
    guard cid != 0 else { return }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return }

    for display in displays {
        guard let currentSpaceDict = display["Current Space"] as? [String: Any],
              let displayCurrent   = (currentSpaceDict["id64"] as? NSNumber)?.uint64Value,
              let spaces           = display["Spaces"] as? [[String: Any]]
        else { continue }

        var spaceIDs   = [CGSSpaceID]()
        var currentIdx = -1
        var targetIdx  = -1

        for space in spaces {
            guard let sid = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            if sid == displayCurrent { currentIdx = spaceIDs.count }
            if sid == targetSpace    { targetIdx  = spaceIDs.count }
            spaceIDs.append(sid)
        }

        // Target not found on this display — try the next one
        guard targetIdx >= 0 else { continue }

        // Already on the target space — nothing to do
        guard targetIdx != currentIdx else { break }

        // Need at least two spaces and a valid current position to navigate
        guard currentIdx >= 0, spaceIDs.count >= 2 else { break }

        // Compute direction and step count for sequential navigation
        let direction = targetIdx > currentIdx ? 1 : -1
        let steps     = abs(targetIdx - currentIdx)
        switchNSpaces(direction: direction, steps: steps)
        break
    }
}

// MARK: - Synthetic DockSwipe Gesture Posting
//
// The Dock watches for DockSwipe gesture events with high velocity.
// When velocity exceeds a threshold, it switches spaces without the
// slide animation. We exploit this by posting synthetic CGEvents
// directly into the session event tap.
//
// Each space switch requires a Began+Ended gesture pair:
//   1. Began  — tells the Dock a swipe started (velocity/progress = 0)
//   2. Ended  — tells the Dock the swipe finished (extreme velocity triggers instant switch)

/// Posts a single gesture event pair (one "gesture" + one "dock control" event).
///
/// Each gesture consists of two CGEvents posted back-to-back:
///   - A generic gesture event (`kCGSEventGesture`) that acts as an envelope
///   - A dock control event (`kCGSEventDockControl`) with the actual swipe data
///
/// Both events must be posted for the Dock to recognize and act on the gesture.
///
/// - Parameters:
///   - flagDirection: `0` for left, `1` for right.
///   - phase: `kCGSGesturePhaseBegan` (1) or `kCGSGesturePhaseEnded` (4).
///   - progress: How far the swipe has gone (only matters for Ended phase).
///   - velocity: How fast the swipe is moving (only matters for Ended phase).
/// - Returns: `true` if the events were created and posted successfully.
private func postGesturePair(flagDirection: Int64, phase: Int64,
                             progress: Double, velocity: Double) -> Bool {
    guard let gestureEvent = CGEvent(source: nil),
          let dockEvent    = CGEvent(source: nil) else { return false }

    // The generic gesture event just needs the event type field set.
    // It acts as a container/envelope that the Dock recognizes.
    gestureEvent.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)

    // The dock control event carries all the actual swipe parameters
    // that determine direction, phase, and intensity.
    dockEvent.setIntegerValueField(kCGSEventTypeField,            value: kCGSEventDockControl)
    dockEvent.setIntegerValueField(kCGEventGestureHIDType,        value: kIOHIDEventTypeDockSwipe)
    dockEvent.setIntegerValueField(kCGEventGesturePhase,          value: phase)
    dockEvent.setIntegerValueField(kCGEventScrollGestureFlagBits, value: flagDirection)
    dockEvent.setIntegerValueField(kCGEventGestureSwipeMotion,    value: 1)
    dockEvent.setDoubleValueField(kCGEventGestureScrollY,          value: 0)

    // A non-zero epsilon in the zoom delta field prevents the Dock from
    // discarding the event as a no-op (it checks for zero and ignores it)
    dockEvent.setDoubleValueField(kCGEventGestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

    // Velocity and progress only matter when the gesture ends —
    // that's when the Dock decides whether to animate or snap instantly
    if phase == kCGSGesturePhaseEnded {
        dockEvent.setDoubleValueField(kCGEventGestureSwipeProgress,  value: progress)
        dockEvent.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: velocity)
        dockEvent.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
    }

    // Post both events into the session event tap where the Dock can see them.
    // The dock control event must be posted first (it carries the payload),
    // followed by the gesture envelope.
    dockEvent.post(tap: .cgSessionEventTap)
    gestureEvent.post(tap: .cgSessionEventTap)
    return true
}

/// Posts a complete Began+Ended gesture pair that triggers an instant space switch.
///
/// The "Began" event tells the Dock a swipe started (with zero velocity).
/// The "Ended" event tells it the swipe finished with extreme velocity,
/// which makes the Dock switch spaces instantly without animation.
///
/// - Parameters:
///   - direction: `-1` for left, `+1` for right.
///   - velocity: Magnitude of the Ended-phase velocity.
/// - Returns: `true` if both gesture phases were posted successfully.
func postSwitchGesture(direction: Int,
                       velocity: Double = kInstantSwitchVelocity) -> Bool {
    let isRight              = direction > 0
    let flagDirection: Int64 = isRight ? 1 : 0
    let progress             = isRight ? kInstantSwitchProgress : -kInstantSwitchProgress
    let signedVelocity       = isRight ? velocity : -velocity

    // Phase 1: Begin the swipe (zero velocity/progress — just a start signal)
    let beganOK = postGesturePair(
        flagDirection: flagDirection,
        phase: kCGSGesturePhaseBegan,
        progress: 0,
        velocity: 0
    )

    // Phase 2: End the swipe with extreme values (triggers instant switch)
    let endedOK = postGesturePair(
        flagDirection: flagDirection,
        phase: kCGSGesturePhaseEnded,
        progress: progress,
        velocity: signedVelocity
    )

    return beganOK && endedOK
}

/// Posts N consecutive space-switch gestures in the given direction.
///
/// Used by auto-follow when the target space is more than one step away.
/// Velocity is scaled by `steps` so the Dock snaps straight to the target
/// rather than animating between intermediate spaces on long jumps.
/// Stops early if any gesture fails (e.g. CGEvent allocation failure).
///
/// - Parameters:
///   - direction: `-1` for left, `+1` for right.
///   - steps: How many spaces to traverse.
private func switchNSpaces(direction: Int, steps: Int) {
    let velocity = kInstantSwitchVelocity * Double(steps)
    for i in 0..<steps where !postSwitchGesture(direction: direction, velocity: velocity) {
        fputs("Space Rabbit: gesture failed at step \(i + 1)/\(steps)\n", stderr)
        break
    }
}
