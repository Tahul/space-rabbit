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

/// Smallest progress value that survives the signed 16.16 IOHID payload
/// used by vertical DockSwipe gestures.
private let kMissionControlEpsilon: Double = 1.0 / 65536.0

// The DockSwipe motion values (`kGestureMotionHorizontal` /
// `kGestureMotionVertical`) are declared once in SwipeIntercept.swift and
// shared with the posting code here.

/// IOHID swipe-mask bit identifying upward Mission Control entry.
private let kIOHIDSwipeUp: Int64 = 1

/// IOHID swipe-mask bit identifying downward Mission Control dismissal.
private let kIOHIDSwipeDown: Int64 = 2

/// Hardened instant-switch velocity used by augmented horizontal gestures and
/// the Instant vertical Mission Control gesture. macOS 27 raised the Dock's
/// horizontal threshold; macOS 26 Mission Control dismissal also needs this
/// extreme value to eliminate its final zoom frames. Note the inverted sign
/// convention on the augmented horizontal path: NEGATIVE velocity and progress
/// move right, positive move left.
private let kAugmentedInstantVelocity: Double = 9999.0

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
/// Also used by the `activeSpaceDidChangeNotification` observer in
/// `main.swift` to confirm a space change was the one auto-follow requested.
///
/// - Returns: An array of space IDs, one per display that has an active space.
func getAllCurrentSpaces() -> [CGSSpaceID] {
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

// MARK: - Mission Control Detection

/// Window layer of the full-screen overlay windows the Dock puts up while
/// a Mission Control-style overview is on screen (`kCGWindowLayer` 18).
/// Nothing else the Dock owns sits at that layer.
private let kMissionControlWindowLayer: Int32 = 18

/// Private `CGSSpaceMask` selecting current OS-managed spaces:
/// `CGSSpaceIncludesCurrent | CGSSpaceIncludesOS`.
private let kCurrentOSSpacesMask: Int32 = (1 << 0) | (1 << 3)

/// Reads whether a Mission Control-style overview (Mission Control, App
/// Exposé, Show Desktop) is currently on screen.
///
/// The overview drives space navigation itself: it consumes the system
/// space shortcuts and trackpad swipes to slide its own carousel. A
/// synthetic DockSwipe posted into it is evaluated against the overview's
/// state instead of the desktop's, so the screen blanks, swipes, and lands
/// back on the space the user started from — no switch at all (issue #16).
/// The existing Space-switch features therefore stand down while it is up
/// and let macOS handle the input natively.
///
/// Detection uses the same marker yabai relies on (`src/mission_control.c`):
/// for the whole duration of the overview the Dock owns a display-sized
/// window at layer 18 on every display. `kCGWindowName` is deliberately not
/// part of the test — it requires Screen Recording permission, which Space
/// Rabbit does not ask for, so it reads as `nil` for every window here.
///
/// - Returns: The overview state, or `nil` when the window list is unavailable.
private func missionControlOverviewActive() -> Bool? {
    guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]]
    else { return nil }

    for window in windowList {
        guard (window["kCGWindowLayer"] as? NSNumber)?.int32Value == kMissionControlWindowLayer,
              (window["kCGWindowOwnerName"] as? String) == "Dock"
        else { continue }

        return true
    }

    return false
}

/// Whether a Mission Control-style overview is currently on screen.
///
/// Existing Space-switch paths preserve their native fallback behavior when
/// the window list cannot be read, treating an unavailable marker as inactive.
///
/// - Returns: `true` while an overview is on screen.
func isMissionControlActive() -> Bool {
    missionControlOverviewActive() ?? false
}

/// Exact Dock-managed overview state used by vertical gesture interception.
enum DockOverviewState: Equatable {
    case desktop
    case missionControl
    case appExpose
}

/// Reads the named OS-managed spaces exposed by WindowServer.
///
/// The layer-18 marker above deliberately groups every overview together for
/// horizontal stand-down. Instant Mission Control needs a narrower answer so
/// it can dismiss Mission Control without hijacking App Exposé or Show Desktop.
private func namedDockOverviewState() -> DockOverviewState? {
    guard let mainConnection = cgsMainConnection,
          let copySpaces = slsCopySpaces,
          let copyName = slsSpaceCopyName else { return nil }

    let cid = mainConnection()
    guard cid != 0,
          let spaces = copySpaces(cid, kCurrentOSSpacesMask)?
              .takeRetainedValue() as? [NSNumber] else { return nil }

    var missionControlVisible = false
    var appExposeVisible = false

    for space in spaces where space.uint64Value != 0 {
        guard let nameRef = copyName(cid, space.uint64Value)?.takeRetainedValue()
        else { continue }

        let name = nameRef as String
        if name == "mission-control" {
            missionControlVisible = true
        } else if name == "show-front" {
            appExposeVisible = true
        }
    }

    guard !missionControlVisible || !appExposeVisible else { return nil }
    if missionControlVisible { return .missionControl }
    if appExposeVisible { return .appExpose }
    return .desktop
}

/// Returns a fail-closed overview state for a new vertical gesture.
///
/// An absent layer marker positively identifies the desktop without requiring
/// the extra SLS symbols. When an overview is visible, its named OS space must
/// identify Mission Control or App Exposé; Show Desktop and conflicting state
/// remain native.
func currentDockOverviewState() -> DockOverviewState? {
    guard let layerActive = missionControlOverviewActive() else { return nil }
    if !layerActive { return .desktop }

    guard let namedState = namedDockOverviewState() else { return nil }

    switch namedState {
    case .missionControl:
        return .missionControl
    case .appExpose:
        return .appExpose
    case .desktop:
        return nil
    }
}

// MARK: - Window-to-Space Mapping

/// Space information for one group of a process's windows.
private struct WindowGroup {
    /// `true` when at least one window in the group is onscreen — i.e.
    /// composited on a currently visible space — which by itself proves
    /// the app is already reachable without switching.
    var hasOnscreenWindow = false

    /// `true` when at least one window in the group lives on more than one
    /// space — the signature of an "All Desktops" Dock assignment (or a
    /// status/desktop window tagged onto every space). Such a window is
    /// reachable from any space, so activating it never navigates anywhere.
    var hasAllSpacesWindow = false

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
/// a valid space are skipped. A window that resolves to MORE than one
/// space is on every space ("All Desktops" assignment) — it only sets the
/// group's `hasAllSpacesWindow` flag and contributes no chase target.
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

        // Ask the private API which space(s) this window lives on
        let windowIDArray = [NSNumber(value: windowID)] as CFArray
        guard let spaces = spacesFor(cid, kSLSSpaceTypeAll, windowIDArray)?
                .takeRetainedValue() as? [NSNumber]
        else { continue }

        // A window on more than one space is assigned to "All Desktops"
        // (Dock icon > Options), or is a status/desktop window tagged onto
        // every space. It is reachable wherever the user is — chasing its
        // first listed (last-used) space would yank them away (issue #10).
        if spaces.count > 1 {
            if isNormal { normal.hasAllSpacesWindow   = true }
            else        { anchored.hasAllSpacesWindow = true }
            continue
        }

        guard let spaceID = spaces.first?.uint64Value, spaceID != 0 else { continue }

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
/// A hidden or minimized window assigned to "All Desktops" also yields 0:
/// it reappears on whatever space the user is on, so following its last-used
/// space would drag the user backwards (issue #10).
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

        // A window on every space ("All Desktops") appears right where the
        // user is the moment the app unhides — native activation never
        // navigates for it, so neither do we (issue #10).
        if group.hasAllSpacesWindow { return 0 }

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

// MARK: - macOS 27 Gesture Augmentation
//
// Starting with macOS 27, the Dock validates incoming DockSwipe events
// against a serialized IOHID queue payload attached to the event under
// field 4205 — bare synthetic gestures (the pre-27 technique below) are
// rejected outright. The fix, reverse-engineered in joshuarli/iss
// (commit 09beeb6), is threefold:
//
//   1. Build the dock event with additional fields the 27 Dock checks
//      (phase mirror, flavor, timestamp, non-zero position).
//   2. Serialize the event with CGEventCreateData, append a raw
//      (length, field 4205) record containing the packed IOHID payload,
//      and rebuild the event with CGEventCreateFromData — the payload
//      field cannot be set through the normal field-setter API.
//   3. Post a full Began+Changed+Ended phase sequence (the pre-27 path
//      gets away with Began+Ended only).
//
// The sign convention also inverted on this path: negative progress and
// velocity move RIGHT, positive move LEFT — the opposite of the legacy
// path, and what joshuarli/iss posts.
//
// Do NOT "un-invert" these signs to match the legacy path. That was tried
// (PR #15, reverted) on the theory that a newer beta had restored the
// normal orientation, and it is what issue #19 reports: every Ctrl+Arrow
// travels the wrong way, so the shortcut walks to the first/last space
// instead of stepping, and at either edge the Dock flashes black and
// rubber-bands back to the space it started on. Measured directly on
// build 26A5388g by posting the augmented sequence and reading the
// resulting index back from CGSCopyManagedDisplaySpaces:
//
//   progress/velocity  +1.0 / +9999  ->  moves LEFT
//   progress/velocity  -1.0 / -9999  ->  moves RIGHT
//
// This is the posting convention only. Reading the direction of a real
// trackpad gesture is a separate question with its own rule — see
// `isRightSwipe` in SwipeIntercept.swift.

/// Whether this macOS release requires the augmented gesture path
/// (macOS 27 and later). Evaluated once on first use.
func requiresEventAugmentation() -> Bool { gAugmentationRequired }

private let gAugmentationRequired: Bool =
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

/// Whether this release uses a vertical DockSwipe schema known to the Instant
/// Mission Control interceptor. Unknown future private schemas stay native.
///
/// - Returns: `true` for the app's supported macOS 15 through macOS 27 range.
func supportsInstantMissionControlInterception() -> Bool {
    let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return (15...27).contains(majorVersion)
}

/// Packed byte sizes of the IOHID structures serialized into the payload.
/// The layouts are `#pragma pack(1)` C structs — serialized field-by-field
/// below because Swift structs make no layout guarantees.
private let kIOHIDFluidTouchGestureDataSize: UInt32 = 40 // 16-byte base + gesture fields
private let kIOHIDVelocityEventDataSize:     UInt32 = 28 // 16-byte base + velocity fields

private extension Data {
    /// Appends a fixed-width integer in little-endian byte order — the
    /// in-memory layout the window server expects for the IOHID payload
    /// (the payload mimics packed C structs on a little-endian machine).
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Converts a double to the signed 16.16 fixed-point representation used
/// inside IOHID event structures. Values too small to register are clamped
/// to the smallest non-zero fixed-point value so their sign survives.
///
/// Some inputs are read back off a *physical* event (the macOS 27 cleanup
/// path mirrors an intercepted Ended), so the conversion never trusts its
/// argument: a non-finite value would trap in `Int64.init`, and an
/// out-of-range one would wrap its sign. Both are reduced to a saturated
/// value instead.
private func doubleToFixed1616(_ value: Double) -> Int32 {
    guard value.isFinite else { return 0 }

    let scaled  = (value * 65536.0).rounded(.towardZero)
    let clamped = min(max(scaled, Double(Int32.min)), Double(Int32.max))
    let fixed   = Int32(clamped)

    if fixed == 0 && value != 0.0 { return value > 0.0 ? 1 : -1 }
    return fixed
}

/// Serializes the IOHID queue payload that macOS 27 validates dock swipes
/// against, mirroring the gesture parameters already set on `event`.
///
/// Layout (all little-endian, packed):
///   - `IOHIDSystemQueueElementHeader` (28 bytes)
///   - `IOHIDFluidTouchGestureData`    (40 bytes) — the swipe itself
///   - `IOHIDVelocityEventData`        (28 bytes) — only when velocity is
///     non-zero or the phase is Ended
///
/// - Parameter event: The dock control event whose fields to mirror.
/// - Returns: The packed payload bytes.
private func generateIOHIDPayload(from event: CGEvent) -> Data {
    let phase     = event.getIntegerValueField(kCGEventGesturePhase)
    let motion    = event.getIntegerValueField(kCGEventGestureSwipeMotion)
    let progress  = event.getDoubleValueField(kCGEventGestureSwipeProgress)
    let posX      = event.getDoubleValueField(kCGEventGesturePositionX)
    let posY      = event.getDoubleValueField(kCGEventGesturePositionY)
    let velX      = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
    let velY      = event.getDoubleValueField(kCGEventGestureSwipeVelocityY)
    let swipeMask = event.getIntegerValueField(kCGEventGestureSwipeMask)

    let includeVelocity = velX != 0.0 || velY != 0.0 || phase == kCGSGesturePhaseEnded

    var payload = Data()

    // IOHIDSystemQueueElementHeader
    let timestamp = event.timestamp != 0 ? UInt64(event.timestamp) : mach_absolute_time()
    payload.appendLE(timestamp)                               // timestamp
    payload.appendLE(UInt64(0))                               // sender_id
    payload.appendLE(UInt32(0))                               // options
    payload.appendLE(UInt32(0))                               // attribute_length
    payload.appendLE(UInt32(includeVelocity ? 2 : 1))         // event_count

    // IOHIDFluidTouchGestureData (IOHIDEventBase + gesture fields)
    payload.appendLE(kIOHIDFluidTouchGestureDataSize)         // base.size
    payload.appendLE(kIOHIDEventTypeFluidTouchGesture)        // base.type
    payload.appendLE(UInt32((phase & 0xFF) << 24))            // base.options: phase in high byte
    payload.appendLE(UInt8(0))                                // base.depth
    payload.append(contentsOf: [0, 0, 0])                     // base.reserved
    payload.appendLE(doubleToFixed1616(posX))                 // position_x
    payload.appendLE(doubleToFixed1616(posY))                 // position_y
    payload.appendLE(Int32(0))                                // position_z
    payload.appendLE(UInt32(truncatingIfNeeded: swipeMask))   // swipe_mask
    payload.appendLE(UInt16(truncatingIfNeeded: motion))      // gesture_motion
    payload.appendLE(kIOHIDGestureFlavorDockPrimary)          // gesture_flavor
    payload.appendLE(doubleToFixed1616(progress))             // swipe_progress

    // IOHIDVelocityEventData (IOHIDEventBase + velocity fields)
    if includeVelocity {
        payload.appendLE(kIOHIDVelocityEventDataSize)         // base.size
        payload.appendLE(kIOHIDEventTypeVelocity)             // base.type
        payload.appendLE(UInt32(0))                           // base.options
        payload.appendLE(UInt8(1))                            // base.depth
        payload.append(contentsOf: [0, 0, 0])                 // base.reserved
        payload.appendLE(doubleToFixed1616(velX))             // velocity_x
        payload.appendLE(doubleToFixed1616(velY))             // velocity_y
        payload.appendLE(Int32(0))                            // velocity_z
    }

    return payload
}

/// Rebuilds `event` with a current IOHID payload in field 4205.
///
/// The payload field cannot be set through `setIntegerValueField`, so the
/// event is flattened with `CGEventCreateData`, any existing field-4205 record
/// is replaced, and a new event is inflated with `CGEventCreateFromData`.
/// Horizontal swipes need this on macOS 27+. FasterSwiper's working vertical
/// path uses it on macOS 26 and 27, so every synthetic Mission Control phase
/// is rebuilt this way on the releases this feature supports.
///
/// - Parameters:
///   - event: The fully-populated dock control event.
///   - mayCarryExistingPayload: `true` when `event` was copied from a real
///     gesture and could already hold a field-4205 record. Such an event is
///     only augmented if the existing record can be positively located and
///     replaced — appending a second, contradictory payload would be worse
///     than not augmenting at all.
/// - Returns: A new event carrying the payload, or `nil` on failure
///            (including an unrecognized serialization format).
private func augmentDockSwipeEvent(_ event: CGEvent,
                                   mayCarryExistingPayload: Bool = false) -> CGEvent? {
    guard let cfData = event.data else { return nil }
    let bytes = cfData as Data

    // Sanity-check the serialization header (version 2) — if Apple changes
    // the format, bail out rather than corrupt the event.
    guard bytes.count >= 4,
          bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2
    else { return nil }

    let payload = generateIOHIDPayload(from: event)
    let augmented: Data

    if let replaced = replacingBinaryField(kCGEventIOHIDPayloadField,
                                           in: bytes, with: payload) {
        augmented = replaced
    } else if mayCarryExistingPayload {
        return nil
    } else {
        // The blob holds a record shape the walker does not recognize. A
        // freshly built event carries no payload of its own, so appending
        // one is unambiguous — and is exactly the behavior that shipped
        // before the walker existed, which keeps an unknown record from
        // silently disabling the macOS 27 horizontal path.
        guard let appended = appendingBinaryField(kCGEventIOHIDPayloadField,
                                                  to: bytes, with: payload)
        else { return nil }
        augmented = appended
    }

    return CGEvent(withDataAllocator: kCFAllocatorDefault, data: augmented as CFData)
}

/// Appends one binary field record to CGEvent's version-2 serialization.
///
/// - Returns: The extended bytes, or `nil` if the payload cannot be framed.
private func appendingBinaryField(_ fieldID: UInt16, to bytes: Data,
                                  with payload: Data) -> Data? {
    guard payload.count <= Int(UInt16.max) else { return nil }

    var result = bytes
    result.append(UInt8(payload.count >> 8))                  // payload length (BE)
    result.append(UInt8(payload.count & 0xFF))
    result.append(UInt8(fieldID >> 8))                        // binary tag is zero
    result.append(UInt8(fieldID & 0xFF))
    result.append(payload)
    return result
}

/// Replaces one binary field in CGEvent's version-2 serialization while
/// preserving all other records byte-for-byte.
///
/// - Returns: The rewritten bytes, or `nil` when a record cannot be walked
///            (an unknown tag, a truncated blob, or an unframeable payload).
private func replacingBinaryField(_ fieldID: UInt16, in bytes: Data,
                                  with payload: Data) -> Data? {
    // `bytes` normally starts at zero, but indexing off `startIndex` keeps
    // this correct if it is ever handed a slice.
    let base = bytes.startIndex
    let end  = bytes.endIndex

    guard bytes.count >= 4 else { return nil }

    var result = Data(bytes.prefix(4))
    var offset = base + 4

    while offset < end {
        guard offset + 4 <= end else { return nil }

        let elementSize = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        let tagAndField = (UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3])
        let tag = tagAndField >> 14
        let currentFieldID = tagAndField & 0x3FFF

        let valueSize: Int
        switch tag {
        case 0 where elementSize == 1: valueSize = 8
        case 0 where elementSize > 1: valueSize = Int(elementSize)
        case 1 where elementSize == 1: valueSize = 4
        case 3 where elementSize == 1: valueSize = 4
        case 3 where elementSize == 2: valueSize = 8
        default: return nil
        }

        let recordEnd = offset + 4 + valueSize
        guard recordEnd <= end else { return nil }
        if currentFieldID != fieldID {
            result.append(bytes.subdata(in: offset..<recordEnd))
        }
        offset = recordEnd
    }

    return appendingBinaryField(fieldID, to: result, with: payload)
}

// MARK: - Mission Control Transition

/// Mission Control's animated path advances progress explicitly; unlike the
/// horizontal DockSwipe path, changing only the terminal velocity after
/// progress has reached ±1 cannot affect the visible transition.
private let kMissionControlAnimationFPS: Double = 120.0
private let kMissionControlAnimationDurationSlow: TimeInterval = 0.24
private let kMissionControlAnimationDurationFast: TimeInterval = 0.08
private let kMissionControlAnimationQueue = DispatchQueue(
    label: "app.spacerabbit.mission-control-animation",
    qos: .userInteractive
)

/// Maps the shared horizontal velocity band to a Mission Control duration.
/// The two private gesture protocols expose different controls (terminal
/// velocity versus timed progress), but the user's one slider remains the
/// source of truth for both.
private func missionControlAnimationDuration(for velocity: Double) -> TimeInterval {
    let fraction = min(max(
        (velocity - kAnimatedVelocityMin)
            / (kAnimatedVelocityMax - kAnimatedVelocityMin),
        0
    ), 1)
    return kMissionControlAnimationDurationSlow
        - (kMissionControlAnimationDurationSlow - kMissionControlAnimationDurationFast)
            * fraction
}

/// Creates one phase of a controlled vertical Mission Control DockSwipe.
///
/// Progress and terminal velocity are explicit because animated transitions
/// send a timed series of Changed samples while Instant jumps directly to the
/// signed boundary. `+1.0` enters Mission Control and `-1.0` dismisses it.
/// Field 129 is the DockSwipe terminal-velocity field for both axes despite its
/// private `VelocityX` name (FasterSwiper uses it for vertical gestures too).
/// macOS 27+ also receives the mirrored fields that feed its validated payload.
///
/// - Parameters:
///   - phase: Began, Changed, or Ended.
///   - direction: `+1` to enter Mission Control, `-1` to dismiss it.
///   - progressMagnitude: Unsigned progress in the `epsilon...1` range.
///   - velocityMagnitude: Optional unsigned Ended velocity.
///   - augmented: Whether to populate the macOS 27+ fields.
/// - Returns: The dock-control event, or `nil` if it cannot be allocated.
private func makeMissionControlDockEvent(phase: Int64,
                                         direction: Int,
                                         progressMagnitude: Double,
                                         velocityMagnitude: Double? = nil,
                                         augmented: Bool) -> CGEvent? {
    guard progressMagnitude > 0, progressMagnitude <= 1,
          let event = CGEvent(source: nil) else { return nil }

    let sign = direction > 0 ? 1.0 : -1.0

    event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
    event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    event.setIntegerValueField(kCGEventGesturePhase, value: phase)
    event.setIntegerValueField(kCGEventGestureSwipeMotion, value: kGestureMotionVertical)
    event.setDoubleValueField(kCGEventGestureSwipeProgress,
                              value: sign * progressMagnitude)

    if let velocityMagnitude {
        event.setDoubleValueField(kCGEventGestureSwipeVelocityX,
                                  value: sign * velocityMagnitude)
        event.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
    }

    if augmented {
        event.setIntegerValueField(kCGEventGestureSwipeMask,
                                   value: direction > 0 ? kIOHIDSwipeUp : kIOHIDSwipeDown)
        event.setIntegerValueField(kCGEventGesturePhase2, value: phase)
        event.setDoubleValueField(kCGEventGestureFlavor,
                                  value: Double(kIOHIDGestureFlavorDockPrimary))
        event.setDoubleValueField(kCGEventGestureTimestamp,
                                  value: Double(mach_absolute_time()))
        event.setDoubleValueField(kCGEventGesturePositionY, value: sign * 0.1)
    }

    return event
}

/// Builds and IOHID-augments one complete vertical event, then marks the
/// rebuilt result so the shared swipe tap recognizes it as synthetic.
private func prepareMissionControlDockEvent(phase: Int64,
                                            direction: Int,
                                            progressMagnitude: Double,
                                            velocityMagnitude: Double? = nil,
                                            augmented: Bool) -> CGEvent? {
    guard let rawEvent = makeMissionControlDockEvent(
        phase: phase,
        direction: direction,
        progressMagnitude: progressMagnitude,
        velocityMagnitude: velocityMagnitude,
        augmented: augmented
    ) else { return nil }

    guard let augmentedEvent = augmentDockSwipeEvent(rawEvent) else { return nil }
    markSyntheticGesture(augmentedEvent)
    return augmentedEvent
}

/// Constructs a complete terminal pair before either event can be posted.
/// Callers retain a pair before Began so allocation or augmentation failure on
/// a later animation tick can never strand an open synthetic Dock gesture.
private func prepareMissionControlAnimationTerminal(
    direction: Int,
    augmented: Bool
) -> MissionControlTerminalEvents? {
    guard let changed = prepareMissionControlDockEvent(
        phase: kCGSGesturePhaseChanged,
        direction: direction,
        progressMagnitude: 1,
        augmented: augmented
    ), let ended = prepareMissionControlDockEvent(
        phase: kCGSGesturePhaseEnded,
        direction: direction,
        progressMagnitude: 1,
        velocityMagnitude: kMissionControlEpsilon,
        augmented: augmented
    ) else { return nil }

    return MissionControlTerminalEvents(changed: changed, ended: ended)
}

/// Posts a prepared terminal pair from the asynchronous animation queue.
private func postMissionControlAnimationTerminal(
    _ terminal: MissionControlTerminalEvents
) {
    terminal.changed.post(tap: .cgSessionEventTap)
    terminal.ended.post(tap: .cgSessionEventTap)
}

/// Posts a prepared terminal pair through the current tap callback. Interrupted
/// animation cleanup and the replacement Began therefore share one injection
/// path and have deterministic ordering.
private func postMissionControlAnimationTerminal(
    _ terminal: MissionControlTerminalEvents,
    proxy: CGEventTapProxy
) {
    terminal.changed.tapPostEvent(proxy)
    terminal.ended.tapPostEvent(proxy)
}

/// Starts a non-blocking progress animation. Every tick creates a fresh event
/// so its timestamp and serialized field-4205 payload agree. The work runs off
/// the event-tap thread; holding that callback for the animation duration would
/// cause macOS to disable the tap.
private func postAnimatedMissionControlTransition(proxy: CGEventTapProxy,
                                                  direction: Int,
                                                  duration: TimeInterval,
                                                  augmented: Bool) -> Bool {
    guard let began = prepareMissionControlDockEvent(
        phase: kCGSGesturePhaseBegan,
        direction: direction,
        progressMagnitude: kMissionControlEpsilon,
        augmented: augmented
    ), let fallbackTerminal = prepareMissionControlAnimationTerminal(
        direction: direction,
        augmented: augmented
    ) else { return false }

    let sampleCount = max(2, Int(ceil(duration * kMissionControlAnimationFPS)))
    let setup: (id: UInt64, interrupted: MissionControlAnimationState?) =
        kMissionControlAnimationQueue.sync {
            let interrupted = gMissionControlAnimation
            gMissionControlAnimationID &+= 1
            let animationID = gMissionControlAnimationID
            gMissionControlAnimation = MissionControlAnimationState(
                id: animationID,
                direction: direction,
                augmented: augmented,
                fallbackTerminal: fallbackTerminal
            )
            return (animationID, interrupted)
        }

    // Keep overlap cleanup and the replacement Began on the same tap proxy.
    // This guarantees the old Ended is observed before the new Began; later
    // animation ticks cannot retain the proxy and use the session tap.
    if let interruptedAnimation = setup.interrupted {
        let terminal = prepareMissionControlAnimationTerminal(
            direction: interruptedAnimation.direction,
            augmented: interruptedAnimation.augmented
        ) ?? interruptedAnimation.fallbackTerminal
        postMissionControlAnimationTerminal(terminal, proxy: proxy)
    }
    began.tapPostEvent(proxy)

    // Do not schedule session-tap samples until Began has been injected.
    let animationID = setup.id
    for index in 1...sampleCount {
        let linearProgress = Double(index) / Double(sampleCount)
        let delay = duration * linearProgress

        kMissionControlAnimationQueue.asyncAfter(deadline: .now() + delay) {
            guard let animation = gMissionControlAnimation,
                  animation.id == animationID else { return }

            // Cubic ease-out closely follows Dock's existing transition:
            // quick initial response with a smooth arrival at the target.
            let easedProgress = 1 - pow(1 - linearProgress, 3)
            let isLast = index == sampleCount

            if isLast {
                let terminal = prepareMissionControlAnimationTerminal(
                    direction: direction,
                    augmented: augmented
                ) ?? animation.fallbackTerminal
                postMissionControlAnimationTerminal(terminal)
                gMissionControlAnimation = nil
                return
            }

            guard let changed = prepareMissionControlDockEvent(
                phase: kCGSGesturePhaseChanged,
                direction: direction,
                progressMagnitude: easedProgress,
                augmented: augmented
            ) else {
                postMissionControlAnimationTerminal(animation.fallbackTerminal)
                gMissionControlAnimation = nil
                return
            }
            changed.post(tap: .cgSessionEventTap)
        }
    }

    return true
}

/// Completes and invalidates any timed animation before an Instant transition.
/// Cleanup uses the active proxy so its Ended is ordered before the new Began.
private func finishAnimatedMissionControlTransitionIfNeeded(
    proxy: CGEventTapProxy
) {
    let interruptedAnimation = kMissionControlAnimationQueue.sync {
        let current = gMissionControlAnimation
        gMissionControlAnimation = nil
        return current
    }

    if let interruptedAnimation {
        let terminal = prepareMissionControlAnimationTerminal(
            direction: interruptedAnimation.direction,
            augmented: interruptedAnimation.augmented
        ) ?? interruptedAnimation.fallbackTerminal
        postMissionControlAnimationTerminal(terminal, proxy: proxy)
    }
}

/// Posts a complete controlled gesture that enters or dismisses Mission Control.
///
/// Animated ticks advance progress asynchronously over a duration derived from
/// the shared speed control. Instant keeps the proven back-to-back boundary
/// jump with hardened terminal velocity. Vertical events carry field 4205 on
/// macOS 26 as well; macOS 27 additionally receives its mirrored fields.
///
/// - Parameters:
///   - proxy: The active swipe-intercept tap proxy.
///   - direction: `+1` to enter Mission Control, `-1` to dismiss it.
/// - Returns: `true` after Instant was posted or an animated sequence was
///            successfully started; otherwise `false` without claiming it.
func postMissionControlTransition(proxy: CGEventTapProxy,
                                  direction: Int) -> Bool {
    guard direction == -1 || direction == 1,
          !isNativeSwitchSpeed() else { return false }

    let velocity = currentSwitchVelocity()
    let needsAugmentation = requiresEventAugmentation()

    if velocity < kInstantSwitchVelocity {
        return postAnimatedMissionControlTransition(
            proxy: proxy,
            direction: direction,
            duration: missionControlAnimationDuration(for: velocity),
            augmented: needsAugmentation
        )
    }

    let phases = [kCGSGesturePhaseBegan, kCGSGesturePhaseChanged,
                  kCGSGesturePhaseEnded]
    var events = [CGEvent]()

    for phase in phases {
        guard let event = prepareMissionControlDockEvent(
            phase: phase,
            direction: direction,
            progressMagnitude: phase == kCGSGesturePhaseBegan
                ? kMissionControlEpsilon : 1,
            velocityMagnitude: phase == kCGSGesturePhaseEnded
                ? kAugmentedInstantVelocity : nil,
            augmented: needsAugmentation
        ) else { return false }
        events.append(event)
    }

    // Only interrupt an existing animation after the replacement sequence is
    // fully constructed. If construction fails, the existing gesture remains
    // valid and the physical event can continue natively.
    finishAnimatedMissionControlTransitionIfNeeded(proxy: proxy)

    for event in events {
        event.tapPostEvent(proxy)
    }
    return true
}

/// Rebuilds a macOS 27 physical vertical Ended event with no movement.
///
/// That release mirrors progress and velocity inside field 4205. Mutating only
/// the ordinary fields leaves contradictory motion in the IOHID payload, so a
/// claimed gesture's terminal cleanup must update both representations.
func makeMissionControlCleanupEvent(from physicalEvent: CGEvent) -> CGEvent? {
    guard requiresEventAugmentation(),
          physicalEvent.getIntegerValueField(kCGEventGestureSwipeMotion)
              == kGestureMotionVertical,
          let cleanup = physicalEvent.copy() else { return nil }

    cleanup.setDoubleValueField(kCGEventGestureSwipeProgress, value: 0)
    cleanup.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0)
    cleanup.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
    return augmentDockSwipeEvent(cleanup, mayCarryExistingPayload: true)
}

/// Creates one phase of the macOS 27 dock swipe, with the extra fields
/// the 27 Dock validates (phase mirror, flavor, timestamp, non-zero
/// position). Progress/velocity signs are INVERTED relative to the
/// legacy path: negative moves right, positive moves left.
///
/// - Parameters:
///   - phase: `kCGSGesturePhaseBegan`, `...Changed`, or `...Ended`.
///   - isRight: `true` to move to the next space (right).
///   - velocity: Velocity magnitude applied on the Ended phase.
/// - Returns: The dock control event (not yet augmented), or `nil`.
private func makeAugmentedDockEvent(phase: Int64, isRight: Bool,
                                    velocity: Double) -> CGEvent? {
    guard let ev = CGEvent(source: nil) else { return nil }

    ev.setIntegerValueField(kCGSEventTypeField,          value: kCGSEventDockControl)
    ev.setIntegerValueField(kCGEventGestureHIDType,      value: kIOHIDEventTypeDockSwipe)
    ev.setIntegerValueField(kCGEventGesturePhase,        value: phase)
    ev.setDoubleValueField(kCGEventGestureSwipeProgress, value: isRight ? -1.0 : 1.0)
    ev.setIntegerValueField(kCGEventGestureSwipeMotion,  value: kGestureMotionHorizontal)
    ev.setIntegerValueField(kCGEventGesturePhase2,       value: phase)
    ev.setDoubleValueField(kCGEventGestureFlavor,        value: Double(kIOHIDGestureFlavorDockPrimary))
    ev.setDoubleValueField(kCGEventGestureTimestamp,     value: Double(mach_absolute_time()))
    ev.setDoubleValueField(kCGEventGesturePositionX,     value: 0.1)

    if phase == kCGSGesturePhaseEnded {
        ev.setDoubleValueField(kCGEventGestureSwipeVelocityX,
                               value: isRight ? -velocity : velocity)
    }
    return ev
}

/// Posts a complete augmented Began+Changed+Ended swipe sequence — the
/// macOS 27 equivalent of `postSwitchGesture`'s legacy Began+Ended pair.
///
/// All three events are built (and augmented) up front so a mid-sequence
/// allocation failure posts nothing at all — a Began without its Ended
/// would leave the Dock's gesture state half-open.
///
/// - Parameters:
///   - isRight: `true` to move to the next space (right).
///   - velocity: Velocity magnitude requested by the caller. Values in
///     the legacy instant range map to `kAugmentedInstantVelocity`;
///     animated-range values pass through unchanged (best effort — the
///     animated band is uncalibrated on macOS 27).
/// - Returns: `true` if the full sequence was posted.
private func postAugmentedSwitchGesture(isRight: Bool, velocity: Double) -> Bool {
    let magnitude = velocity >= kInstantSwitchVelocity
        ? kAugmentedInstantVelocity : velocity

    let phases = [kCGSGesturePhaseBegan, kCGSGesturePhaseChanged, kCGSGesturePhaseEnded]
    var events = [(dock: CGEvent, gesture: CGEvent)]()

    for phase in phases {
        guard let dockEvent = makeAugmentedDockEvent(phase: phase, isRight: isRight,
                                                     velocity: magnitude)
        else { return false }

        guard let augmented    = augmentDockSwipeEvent(dockEvent),
              let gestureEvent = CGEvent(source: nil)
        else { return false }

        // CGEventCreateFromData does not preserve eventSourceUserData, so
        // stamp the rebuilt event before posting it through the swipe tap.
        markSyntheticGesture(augmented)

        // The companion gesture envelope needs no augmentation
        gestureEvent.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)
        markSyntheticGesture(gestureEvent)
        events.append((augmented, gestureEvent))
    }

    for (dock, gesture) in events {
        dock.post(tap: .cgSessionEventTap)
        gesture.post(tap: .cgSessionEventTap)
    }
    return true
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
    dockEvent.setIntegerValueField(kCGEventGestureSwipeMotion,    value: kGestureMotionHorizontal)
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

    // Post both events into the session event tap where the Dock can see
    // them. The dock control event must be posted first (it carries the
    // payload), followed by the gesture envelope. The swipe-intercept tap
    // (Feature 3) sees these too — stamp them so it passes them through.
    markSyntheticGesture(dockEvent)
    markSyntheticGesture(gestureEvent)
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
/// On macOS 27 and later, routes to the augmented Began+Changed+Ended
/// sequence instead — the Dock there rejects bare synthetic gestures
/// (see the "macOS 27 Gesture Augmentation" section above).
///
/// - Parameters:
///   - direction: `-1` for left, `+1` for right.
///   - velocity: Magnitude of the Ended-phase velocity.
/// - Returns: `true` if both gesture phases were posted successfully.
func postSwitchGesture(direction: Int,
                       velocity: Double = currentSwitchVelocity()) -> Bool {
    guard (direction == -1 || direction == 1),
          !isNativeSwitchSpeed(),
          velocity > 0 else { return false }

    let isRight              = direction > 0

    if requiresEventAugmentation() {
        return postAugmentedSwitchGesture(isRight: isRight, velocity: velocity)
    }

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
