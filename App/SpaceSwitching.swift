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

// MARK: - Space Layout Queries

/// Returns the space IDs for the display that contains the active space,
/// along with the index of the active space within that list.
///
/// This is used by the event tap to check whether a left/right switch
/// is possible (i.e., we're not already at the edge).
///
/// - Returns: A tuple of (space IDs on the active display, index of current space).
///            Returns ([], -1) if the space layout cannot be determined.
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

    // Walk each display to find the one containing the active space
    for display in displays {
        guard let curSD    = display["Current Space"] as? [String: Any],
              let curSID   = (curSD["id64"] as? NSNumber)?.uint64Value,
              curSID == active,
              let spaces   = display["Spaces"] as? [[String: Any]]
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
private func getAllCurrentSpaces() -> [CGSSpaceID] {
    guard let mainConn    = cgsMainConnection,
          let getDisplays = cgsCopyDisplaySpaces else { return [] }

    let cid = mainConn()
    guard cid != 0 else { return [] }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return [] }

    return displays.compactMap { display -> CGSSpaceID? in
        guard let curSD = display["Current Space"] as? [String: Any],
              let sid   = (curSD["id64"] as? NSNumber)?.uint64Value,
              sid != 0  else { return nil }
        return sid
    }
}

/// Finds the space that contains the frontmost window of a given process.
///
/// Walks the system window list to find normal, on-screen windows
/// belonging to the PID, then uses the private SLSCopySpacesForWindows
/// API to determine which space each window is on.
///
/// - Parameter pid: The process ID of the app to locate.
/// - Returns: The space ID to switch to, or 0 if the app is already
///            accessible on a current space (no switch needed).
func findSpaceForPid(_ pid: pid_t) -> CGSSpaceID {
    guard let mainConn  = cgsMainConnection,
          let spacesFor = slsCopySpacesForWindows else { return 0 }

    let cid = mainConn()
    guard cid != 0 else { return 0 }

    let currentSpaces = getAllCurrentSpaces()

    guard let winList = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]]
    else { return 0 }

    var firstOffScreenSpace: CGSSpaceID = 0

    for win in winList {
        // Filter to windows belonging to the target process
        guard (win["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid else { continue }

        // Skip non-normal windows (menus, tooltips, status items, etc.)
        if let layer    = (win["kCGWindowLayer"]     as? NSNumber)?.int32Value, layer    != 0 { continue }
        // Skip offscreen/hidden windows
        if let onscreen = (win["kCGWindowIsOnscreen"] as? NSNumber)?.int32Value, onscreen == 0 { continue }

        guard let wid = (win[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }

        // Ask the private API which space this window is on
        let widArr = [NSNumber(value: wid)] as CFArray
        guard let spaces = spacesFor(cid, 7, widArr)?.takeRetainedValue() as? [NSNumber],
              let spaceNum = spaces.first else { continue }

        let sid = spaceNum.uint64Value
        guard sid != 0 else { continue }

        // If any window is already on a current space, the app is reachable —
        // don't follow. This prevents auto-follow from chasing a second window
        // on a different space when the user is already on the right one.
        if currentSpaces.contains(sid) { return 0 }

        // Remember the first off-screen space we find
        if firstOffScreenSpace == 0 { firstOffScreenSpace = sid }
    }

    return firstOffScreenSpace
}

/// Returns true if every normal, on-screen window of the process is on
/// `targetSpace` — meaning no window lives on any other space.
///
/// Call this at notification time (before switchToSpace), while the CGS
/// state is still fresh.  The result tells the caller whether it is safe
/// to call activate(.activateAllWindows) after switching: that flag asks
/// macOS to raise every window of the app, which triggers a native
/// cross-space switch for any window that lives on a different space.
/// When this returns false (windows on multiple spaces), we fall back to
/// activate([]) so we stay on the space we just switched to.
func appWindowsConfinedToSpace(_ pid: pid_t, _ targetSpace: CGSSpaceID) -> Bool {
    guard let mainConn  = cgsMainConnection,
          let spacesFor = slsCopySpacesForWindows else { return true }

    let cid = mainConn()
    guard cid != 0 else { return true }

    guard let winList = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]]
    else { return true }

    for win in winList {
        guard (win["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid else { continue }
        if let layer    = (win["kCGWindowLayer"]     as? NSNumber)?.int32Value, layer    != 0 { continue }
        if let onscreen = (win["kCGWindowIsOnscreen"] as? NSNumber)?.int32Value, onscreen == 0 { continue }

        guard let wid = (win[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
        let widArr = [NSNumber(value: wid)] as CFArray
        guard let spaces = spacesFor(cid, 7, widArr)?.takeRetainedValue() as? [NSNumber],
              let sid = spaces.first?.uint64Value, sid != 0 else { continue }

        if sid != targetSpace { return false }
    }

    return true
}

/// Switches to the space identified by `targetSpace` on whichever display contains it.
///
/// Computes the minimum number of directional steps from the current space
/// to the target and posts that many gesture pairs.
func switchToSpace(_ targetSpace: CGSSpaceID) {
    guard let mainConn    = cgsMainConnection,
          let getDisplays = cgsCopyDisplaySpaces else { return }

    let cid = mainConn()
    guard cid != 0 else { return }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return }

    for display in displays {
        guard let curSD = display["Current Space"] as? [String: Any],
              let displayCurrent = (curSD["id64"] as? NSNumber)?.uint64Value,
              let spaces = display["Spaces"] as? [[String: Any]]
        else { continue }

        var sids       = [CGSSpaceID]()
        var currentIdx = -1
        var targetIdx  = -1

        for space in spaces {
            guard let val = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            if val == displayCurrent { currentIdx = sids.count }
            if val == targetSpace    { targetIdx  = sids.count }
            sids.append(val)
        }

        guard targetIdx  >= 0              else { continue }  // Target not on this display
        guard targetIdx  != currentIdx     else { break }     // Already on the target space
        guard currentIdx >= 0, sids.count >= 2 else { break }

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
///   - A generic gesture event (kCGSEventGesture) that acts as an envelope
///   - A dock control event (kCGSEventDockControl) with the actual swipe data
///
/// - Parameters:
///   - flagDirection: 0 for left, 1 for right.
///   - phase: kCGSGesturePhaseBegan (1) or kCGSGesturePhaseEnded (4).
///   - progress: How far the swipe has gone (only matters for Ended phase).
///   - velocity: How fast the swipe is moving (only matters for Ended phase).
/// - Returns: true if the events were created and posted successfully.
private func postGesturePair(flagDirection: Int64, phase: Int64,
                             progress: Double, velocity: Double) -> Bool {
    guard let gestureEv = CGEvent(source: nil),
          let dockEv    = CGEvent(source: nil) else { return false }

    // The generic gesture event just needs the event type field set
    gestureEv.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)

    // The dock control event carries all the swipe parameters
    dockEv.setIntegerValueField(kCGSEventTypeField,            value: kCGSEventDockControl)
    dockEv.setIntegerValueField(kCGEventGestureHIDType,        value: kIOHIDEventTypeDockSwipe)
    dockEv.setIntegerValueField(kCGEventGesturePhase,          value: phase)
    dockEv.setIntegerValueField(kCGEventScrollGestureFlagBits, value: flagDirection)
    dockEv.setIntegerValueField(kCGEventGestureSwipeMotion,    value: 1)
    dockEv.setDoubleValueField(kCGEventGestureScrollY,          value: 0)

    // A non-zero epsilon in the zoom delta field prevents the Dock from
    // discarding the event as a no-op
    dockEv.setDoubleValueField(kCGEventGestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

    // Velocity and progress only matter when the gesture ends —
    // that's when the Dock decides whether to animate or snap
    if phase == kCGSGesturePhaseEnded {
        dockEv.setDoubleValueField(kCGEventGestureSwipeProgress,  value: progress)
        dockEv.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: velocity)
        dockEv.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
    }

    // Post both events into the session event tap where the Dock can see them
    dockEv.post(tap: .cgSessionEventTap)
    gestureEv.post(tap: .cgSessionEventTap)
    return true
}

/// Posts a complete Began+Ended gesture pair that triggers an instant space switch.
///
/// - Parameter direction: -1 for left, +1 for right.
/// - Returns: true if both gesture phases were posted successfully.
func postSwitchGesture(direction: Int) -> Bool {
    let isRight       = direction > 0
    let flagDirection: Int64 = isRight ? 1 : 0
    let progress      = isRight ? 2.0 : -2.0    // +-2.0 = fully committed swipe
    let velocity      = isRight ? 400.0 : -400.0 // +-400 = well above the "instant" threshold

    return postGesturePair(flagDirection: flagDirection, phase: kCGSGesturePhaseBegan,
                           progress: 0, velocity: 0)
        && postGesturePair(flagDirection: flagDirection, phase: kCGSGesturePhaseEnded,
                           progress: progress, velocity: velocity)
}

/// Posts N consecutive space-switch gestures in the given direction.
///
/// Used by auto-follow when the target space is more than one step away.
/// Stops early if any gesture fails.
private func switchNSpaces(direction: Int, steps: Int) {
    for i in 0..<steps where !postSwitchGesture(direction: direction) {
        fputs("Space Rabbit: gesture failed at step \(i + 1)/\(steps)\n", stderr)
        break
    }
}
