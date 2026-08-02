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

import AppKit
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

/// Velocity range for animated (non-instant) switches, mapped from the
/// user's transition-speed slider. Calibrated against InstantSpaceSwitcher's
/// speed presets (Fast=50, Faster=60, Fastest=80): the slider's animated
/// ticks at 0.25/0.50/0.75 interpolate to 50/60/70 — the Dock treats
/// velocities well above that band as instant.
private let kAnimatedVelocityMin: Double = 40.0
private let kAnimatedVelocityMax: Double = 80.0

/// Whether switches should use macOS's native animation (slider at the
/// "Normal" tick). At this setting Space Rabbit posts no gestures at all:
/// the event tap passes shortcuts through and auto-follow stands down,
/// so the OS performs its default animated switch.
func isNativeSwitchSpeed() -> Bool {
    gSwitchSpeed <= 0.0
}

/// Returns the gesture velocity for the current transition-speed setting:
/// `kInstantSwitchVelocity` when the slider sits at its "Instant" end cap
/// (`gSwitchSpeed == 1.0`), otherwise a velocity interpolated within the
/// animated range so the Dock plays a slide at the chosen speed.
/// Not meaningful at the "Normal" tick — callers check `isNativeSwitchSpeed()`
/// first and never post gestures there.
func currentSwitchVelocity() -> Double {
    guard gSwitchSpeed < 1.0 else { return kInstantSwitchVelocity }
    return kAnimatedVelocityMin + (kAnimatedVelocityMax - kAnimatedVelocityMin) * gSwitchSpeed
}

// MARK: - Space Layout Queries

/// Returns the space IDs for the display the cursor is currently over,
/// along with the index of that display's active space within the list.
///
/// This matches native macOS behaviour: Ctrl+Arrow switches spaces on the
/// display the cursor hovers, regardless of which display has keyboard focus.
/// Falls back to the focused display when the cursor's display cannot be
/// resolved (e.g. private-API failure).
///
/// - Returns: A tuple of (space IDs on the cursor's display, index of current space).
///            Returns `([], -1)` if the space layout cannot be determined.
func getSpaceList() -> (ids: [CGSSpaceID], currentIdx: Int) {
    guard let mainConn    = cgsMainConnection,
          let getDisplays = cgsCopyDisplaySpaces else { return ([], -1) }

    let cid = mainConn()
    guard cid != 0 else { return ([], -1) }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return ([], -1) }

    /// Extracts the ordered space IDs and current-space index from one
    /// display dictionary, or `nil` if the dictionary is malformed.
    func spaceList(of display: [String: Any]) -> (ids: [CGSSpaceID], currentIdx: Int)? {
        guard let currentSpaceDict = display["Current Space"] as? [String: Any],
              let currentSpaceID   = (currentSpaceDict["id64"] as? NSNumber)?.uint64Value,
              let spaces           = display["Spaces"] as? [[String: Any]]
        else { return nil }

        var ids        = [CGSSpaceID]()
        var currentIdx = -1

        for space in spaces {
            guard let sid = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            if sid == currentSpaceID { currentIdx = ids.count }
            ids.append(sid)
        }

        return (ids, currentIdx)
    }

    let cursorUUID = displayUUIDUnderCursor()
    let active     = cgsGetActiveSpace?(cid) ?? 0

    // Pass 1: prefer the display under the cursor — matches native
    // Ctrl+Arrow behaviour on multi-monitor setups where cursor and
    // keyboard focus may differ. Some systems report the literal
    // identifier "Main" instead of a UUID (notably single-display setups);
    // translate it to the primary display's UUID before comparing.
    if let cursorUUID {
        for display in displays {
            guard let du = display["Display Identifier"] as? String,
                  displayIdentifierMatches(du, uuid: cursorUUID) else { continue }
            if let result = spaceList(of: display) { return result }
        }
    }

    // Pass 2: no display matched the cursor (resolution failure, or an
    // identifier form we don't recognize) — fall back to whichever display
    // hosts the globally active space. Without this net, a mismatch would
    // disable edge bounds-checking and Desktop-N shortcuts entirely.
    if active != 0 {
        for display in displays {
            guard let currentSpaceDict = display["Current Space"] as? [String: Any],
                  let currentSpaceID   = (currentSpaceDict["id64"] as? NSNumber)?.uint64Value,
                  currentSpaceID == active else { continue }
            if let result = spaceList(of: display) { return result }
        }
    }

    return ([], -1)
}

/// Returns the IDs of all user desktops across every display, matching
/// Mission Control's "Desktop N" numbering.
///
/// Mission Control numbers only user desktops (`type` 0) — fullscreen and
/// system spaces are skipped, so including them here would shift every
/// "Switch to Desktop N" binding once a fullscreen app exists. With
/// "Displays have separate Spaces" the numbering continues across displays
/// in the order the window server reports them.
///
/// - Returns: Ordered user-desktop space IDs, or `[]` if the layout
///            cannot be determined.
func getUserDesktops() -> [CGSSpaceID] {
    guard let mainConn    = cgsMainConnection,
          let getDisplays = cgsCopyDisplaySpaces else { return [] }

    let cid = mainConn()
    guard cid != 0 else { return [] }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return [] }

    var desktops = [CGSSpaceID]()
    for display in displays {
        guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
        for space in spaces {
            guard let sid = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            // A missing "type" is treated as a user desktop (type 0)
            let type = (space["type"] as? NSNumber)?.intValue ?? 0
            if type == 0 { desktops.append(sid) }
        }
    }
    return desktops
}

/// Returns the UUID string of the primary display — the one CGS calls
/// "Main" in `CGSCopyManagedDisplaySpaces` dictionaries — or `nil` if it
/// cannot be determined.
private func mainDisplayUUID() -> String? {
    // CGDisplayCreateUUIDFromDisplayID returns nil for a stale display ID
    // (possible mid display-reconfiguration) — never force-unwrap it
    guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?
        .takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String?
}

/// Compares a `"Display Identifier"` dictionary value against a display
/// UUID, translating the literal `"Main"` (used by some systems instead
/// of a UUID — see issue #6) to the primary display's UUID.
private func displayIdentifierMatches(_ identifier: String, uuid: String) -> Bool {
    if identifier == "Main" { return mainDisplayUUID() == uuid }
    return identifier == uuid
}

/// Returns the "Display Identifier" UUID string for the display the cursor
/// is currently over, or `nil` if it cannot be determined.
private func displayUUIDUnderCursor() -> String? {
    let point = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
          let displayID = screen.deviceDescription[
              NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          // nil for a stale display ID (mid display-reconfiguration)
          let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String?
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

/// Space information for one group of a process's windows.
private struct WindowGroup {
    /// `true` when at least one window in the group is onscreen — i.e.
    /// composited on a currently visible space — which by itself proves
    /// the app is already reachable without switching.
    var hasOnscreenWindow = false

    /// Spaces of the group's non-onscreen windows, in front-to-back order.
    var offscreenSpaces: [CGSSpaceID] = []
}

/// Maps the given process's windows to their spaces, split into two groups:
///
/// - `normal`: layer-0 windows (regular app windows — excludes menus,
///   tooltips, status items, etc.)
/// - `anchored`: space-anchored windows at any other layer (Finder's
///   desktop-icons window, status-item windows of menu-bar apps).
///   Used as a fallback by `findSpaceForPid` — see there.
///
/// `kCGWindowIsOnscreen` is present only when a window is composited on a
/// currently visible space — it can NOT distinguish "on another space"
/// from "minimized/hidden"; both simply lack the key. Onscreen windows
/// short-circuit (no space lookup needed: onscreen implies reachable);
/// every other window is resolved to its space via the private
/// `SLSCopySpacesForWindows` API, and windows that cannot be resolved to
/// a valid space are skipped.
///
/// - Parameter pid: The Unix process ID of the target application.
/// - Returns: The process's normal and anchored window groups.
private func visibleWindowSpaces(for pid: pid_t) -> (normal: WindowGroup, anchored: WindowGroup) {
    guard let mainConn  = cgsMainConnection,
          let spacesFor = slsCopySpacesForWindows else { return (WindowGroup(), WindowGroup()) }

    let cid = mainConn()
    guard cid != 0 else { return (WindowGroup(), WindowGroup()) }

    guard let windowList = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]]
    else { return (WindowGroup(), WindowGroup()) }

    var normal   = WindowGroup()
    var anchored = WindowGroup()

    for window in windowList {
        // Only consider windows owned by the target process
        guard (window["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid else { continue }

        let isNormal = ((window["kCGWindowLayer"] as? NSNumber)?.int32Value ?? 0) == 0

        // Onscreen — the app is visible right now, no lookup needed
        if (window["kCGWindowIsOnscreen"] as? NSNumber)?.boolValue == true {
            if isNormal { normal.hasOnscreenWindow   = true }
            else        { anchored.hasOnscreenWindow = true }
            continue
        }

        guard let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        else { continue }

        // Ask the private API which space this window lives on
        let windowIDArray = [NSNumber(value: windowID)] as CFArray
        guard let spaces = spacesFor(cid, kSLSSpaceTypeAll, windowIDArray)?
                .takeRetainedValue() as? [NSNumber],
              let spaceID = spaces.first?.uint64Value,
              spaceID != 0
        else { continue }

        if isNormal { normal.offscreenSpaces.append(spaceID)   }
        else        { anchored.offscreenSpaces.append(spaceID) }
    }

    return (normal, anchored)
}

// MARK: - Process Space Lookup

/// Finds the space that should be switched to when activating the given process.
///
/// Walks the process's visible windows (in front-to-back order) and determines
/// whether any of them are already on a currently-visible display. If so, no
/// switch is needed and this returns 0. Otherwise, it returns the space of the
/// frontmost off-screen window.
///
/// When the process has no normal windows at all, falls back to its
/// space-anchored helper windows: macOS's own activation logic still
/// navigates to those (with the slide animation) — e.g. Finder's
/// desktop-icons window or the status-item windows of menu-bar apps,
/// all typically anchored to the first space. Returning their space
/// lets auto-follow preempt that native animated switch with an
/// instant one to the same destination.
///
/// - Parameter pid: The Unix process ID of the app to locate.
/// - Returns: The space ID to switch to, or `0` if the app is already
///            accessible on a visible space (no switch needed).
func findSpaceForPid(_ pid: pid_t) -> CGSSpaceID {
    let currentSpaces = getAllCurrentSpaces()
    let (normal, anchored) = visibleWindowSpaces(for: pid)

    /// Destination derived from one window group: `0` when the group proves
    /// the app already reachable, the frontmost off-screen window's space to
    /// chase (first in the list — CGWindowList is front-to-back), or `nil`
    /// when the group has no windows to go by.
    func destination(for group: WindowGroup) -> CGSSpaceID? {
        // An onscreen window means the app is visible right now
        if group.hasOnscreenWindow { return 0 }

        // A non-onscreen window whose space is currently visible is
        // minimized or hidden: native activation doesn't navigate anywhere
        // for those, so neither do we.
        //
        // Known limitation: a minimized window whose home space is NOT
        // visible is indistinguishable from a regular window on another
        // space (see visibleWindowSpaces), so it may still be chased.
        for sid in group.offscreenSpaces where currentSpaces.contains(sid) {
            return 0
        }
        return group.offscreenSpaces.first
    }

    if let target = destination(for: normal) { return target }

    // No normal windows anywhere — fall back to space-anchored helper
    // windows, which macOS would otherwise navigate to with an animated
    // switch.
    return destination(for: anchored) ?? 0
}


/// Outcome of a `switchToSpace` request. The three cases matter to the
/// event tap, which must decide whether to swallow the triggering key
/// event or pass it through to macOS's native handler.
enum SpaceSwitchResult {
    /// Switch gestures were posted — the space change is handled by us.
    case switched
    /// The target space is already frontmost on its display — nothing to do,
    /// and no native fallback is wanted (it would just bounce or no-op).
    case alreadyThere
    /// Space Rabbit stood down: layout unknown, private-API failure, or a
    /// cross-display target at an animated speed. The caller should let
    /// macOS handle the switch natively (e.g. pass the key event through).
    case declined
}

/// Switches to the space identified by `targetSpace` on whichever display
/// contains it.
///
/// Walks the space layout for all displays, finds which one contains both
/// the current and target spaces, computes the minimum number of directional
/// steps, and posts that many gesture pairs.
///
/// - Parameter targetSpace: The space ID to switch to.
/// - Returns: See `SpaceSwitchResult`.
func switchToSpace(_ targetSpace: CGSSpaceID) -> SpaceSwitchResult {
    guard let mainConn    = cgsMainConnection,
          let getDisplays = cgsCopyDisplaySpaces else { return .declined }

    let cid = mainConn()
    guard cid != 0 else { return .declined }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return .declined }

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
        guard targetIdx != currentIdx else { return .alreadyThere }

        // Need at least two spaces and a valid current position to navigate
        guard currentIdx >= 0, spaceIDs.count >= 2 else { return .declined }

        // Compute direction and step count for sequential navigation
        let direction = targetIdx > currentIdx ? 1 : -1
        let steps     = abs(targetIdx - currentIdx)

        // The synthetic DockSwipe gesture carries no display information —
        // the Dock applies it to the display under the cursor, so it only
        // works directly when the target space is on the cursor's display.
        //
        // Do NOT be tempted by CGSManagedDisplaySetCurrentSpace for the
        // cross-display case: it flips the window server's current-space
        // pointer without running the actual transition, desyncing state —
        // windows from the target space composite on top of the still-
        // displayed space (worst with fullscreen spaces), and later edge
        // bounds-checks read the stale pointer and overshoot into a black
        // non-existent space.
        let onCursorDisplay: Bool
        if let cursorUUID = displayUUIDUnderCursor(),
           let du = display["Display Identifier"] as? String {
            onCursorDisplay = displayIdentifierMatches(du, uuid: cursorUUID)
        } else {
            // Fail-closed: cursor display unknown — never post blind.
            onCursorDisplay = false
        }

        if onCursorDisplay {
            switchNSpaces(direction: direction, steps: steps)
            return .switched
        }

        // Target lives on another display (or the cursor couldn't be
        // resolved): try the cursor-warp trick; when it declines, report
        // that so the caller can fall back to macOS's native switch.
        return switchOnOtherDisplay(display, direction: direction, steps: steps)
            ? .switched : .declined
    }

    return .declined
}

// MARK: - Cross-Display Switching (Cursor Warp)

/// How long the cursor stays parked on the target display after a
/// cross-display warp switch before being restored. The Dock samples the
/// cursor position asynchronously while processing the posted gesture,
/// so restoring too early would re-route the switch to the wrong display.
private let kCursorWarpRestoreDelay: TimeInterval = 0.15

/// Performs an instant switch on a display other than the cursor's, by
/// briefly warping the cursor onto that display so the Dock applies the
/// posted gesture there, then restoring it.
///
/// Only used at the "Instant" transition speed: the warp trick is
/// unavoidably instant, and at animated speeds macOS's native animated
/// switch (which takes over when this returns `false`) already plays the
/// animation on the correct display.
///
/// `CGWarpMouseCursorPosition` generates no mouse events, and the gesture
/// events are created *after* the warp, so both their embedded location
/// and the live cursor position point at the target display when the Dock
/// looks. The restore is skipped if the user moved the cursor meanwhile —
/// never yank it out from under them.
///
/// - Parameters:
///   - display: The `CGSCopyManagedDisplaySpaces` dictionary of the
///     display hosting the target space.
///   - direction: `-1` for left, `+1` for right.
///   - steps: How many spaces to traverse.
/// - Returns: `true` if gestures were posted via the warp trick.
private func switchOnOtherDisplay(_ display: [String: Any],
                                  direction: Int, steps: Int) -> Bool {
    guard gSwitchSpeed >= 1.0,
          let du = display["Display Identifier"] as? String,
          let targetDisplay = displayID(forIdentifier: du),
          let originalPos = CGEvent(source: nil)?.location
    else { return false }

    let bounds    = CGDisplayBounds(targetDisplay)
    let warpPoint = CGPoint(x: bounds.midX, y: bounds.midY)
    CGWarpMouseCursorPosition(warpPoint)

    switchNSpaces(direction: direction, steps: steps)

    DispatchQueue.main.asyncAfter(deadline: .now() + kCursorWarpRestoreDelay) {
        guard let now = CGEvent(source: nil)?.location,
              abs(now.x - warpPoint.x) <= 2, abs(now.y - warpPoint.y) <= 2
        else { return }
        CGWarpMouseCursorPosition(originalPos)
    }

    return true
}

/// Resolves a `"Display Identifier"` string (a UUID, or the literal
/// `"Main"` — see issue #6) to a CoreGraphics display ID, or `nil` if
/// it cannot be resolved.
private func displayID(forIdentifier identifier: String) -> CGDirectDisplayID? {
    if identifier == "Main" { return CGMainDisplayID() }
    guard let cfUUID = CFUUIDCreateFromString(nil, identifier as CFString) else { return nil }
    let id = CGDisplayGetDisplayIDFromUUID(cfUUID)
    return id == 0 ? nil : id
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
                       velocity: Double = currentSwitchVelocity()) -> Bool {
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
    let velocity = currentSwitchVelocity() * Double(steps)
    for i in 0..<steps where !postSwitchGesture(direction: direction, velocity: velocity) {
        fputs("Space Rabbit: gesture failed at step \(i + 1)/\(steps)\n", stderr)
        break
    }
}
