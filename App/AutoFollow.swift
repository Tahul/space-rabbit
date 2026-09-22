/*
 * AutoFollow.swift — Feature 2: Auto-follow on Cmd+Tab
 *
 * When the user activates an app (via Cmd+Tab, Dock click, etc.),
 * this observer checks whether the app's windows are on a different space.
 * If so, it switches to that space instantly, then brings the app to front.
 *
 * This makes Cmd+Tab behave as if all apps are on the current space —
 * you never see the slow sliding animation to reach a distant desktop.
 */

import AppKit
import ApplicationServices

// MARK: - Constants

/// How long after an instant-switch to suppress auto-follow (in seconds).
///
/// When the user presses Control+Arrow, our event tap posts a gesture
/// that switches spaces. macOS then fires an app-activation notification
/// for whatever app lands in focus on the new space. Without this guard,
/// auto-follow would see that notification and potentially chase a second
/// window of the same app on yet another space, causing a visual glitch.
///
/// 300ms is wide enough to cover the notification delay but narrow enough
/// not to interfere with a real Cmd+Tab shortly after.
///
/// It deliberately does NOT cover space changes auto-follow itself caused —
/// see `gAutoFollowTargetSpace`.
private let kAutoFollowSuppressionWindow: TimeInterval = 0.3

/// How long after following an app a second activation notification for
/// *that same app* is treated as the echo of our own switch rather than a
/// new user action.
///
/// macOS finishes activating the app after the space settles and can fire
/// another notification for it; chasing that would hop to another of the
/// app's windows on yet another space. The guard is scoped to the same PID
/// and torn down the moment any other app activates, so hammering Cmd+Tab
/// between two apps is never suppressed (issue #24).
private let kAutoFollowEchoWindow: TimeInterval = 0.3

/// How long a recorded `gAutoFollowTargetSpace` stays credible as the cause
/// of an incoming `activeSpaceDidChangeNotification`.
///
/// That notification is delivered only once the transition settles, so the
/// window has to be generous — but not unbounded, or a switch that never
/// landed (private-API failure, the user swiping away mid-flight) would
/// silently swallow the stamp for an unrelated space change much later.
let kAutoFollowSelfChangeWindow: TimeInterval = 1.5

/// How long after a key-down matching the auto-follow ignore list an app
/// activation is attributed to that hotkey (see `gLastHotkeyChordTime`).
///
/// Hotkey handlers activate their app within a few tens of milliseconds
/// of the key-down; 300ms covers scheduling delay under load while
/// staying well below the time between pressing a hotkey and separately
/// reaching for Cmd+Tab or the Dock.
private let kAutoFollowIgnoredHotkeyWindow: TimeInterval = 0.3

/// How recently a mouse-down (either button) must have occurred for an
/// activation to be attributed to a click, paired with the pointer sitting inside one of
/// the activated app's onscreen windows (see
/// `pointerInsideOnscreenWindow`).
///
/// Click-to-activation is normally a few tens of milliseconds; 0.5s covers
/// a slow app response without catching activations that merely happen
/// some time after an unrelated click. A miss in either direction falls
/// back to behavior that already exists: macOS's native handling, or
/// today's chase.
private let kAutoFollowClickWindow: TimeInterval = 0.5

/// Poll only while a follow is outstanding; successful switches get no AX
/// messages, and the focus state bounds the entire watch to 1.5 seconds.
private let kAutoFollowFocusPollInterval: TimeInterval = 0.025

/// An unresponsive target must not block the main run loop (and its event
/// taps) for Accessibility's default multi-second messaging timeout.
private let kAutoFollowAXTimeout: Float = 0.05

// MARK: - Arrival Focus Recovery

/// Inputs that supersede a pending follow. Modifier releases are deliberately
/// excluded: releasing Command is part of the Cmd-Tab that started it.
private func autoFollowInputCounts() -> [UInt32] {
    [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].map {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
    }
}

/// A concrete window and the user intent that authorized following it. Main
/// thread only; identity also invalidates callbacks from superseded follows.
private final class AutoFollowFocusRequest {
    let app: NSRunningApplication
    let space: CGSSpaceID
    let windowID: CGWindowID
    let transitSpaces: Set<CGSSpaceID>
    let inputCounts = autoFollowInputCounts()
    var state: AutoFollowFocusState

    init(app: NSRunningApplication, space: CGSSpaceID, windowID: CGWindowID,
         transitSpaces: Set<CGSSpaceID>) {
        self.app = app
        self.space = space
        self.windowID = windowID
        self.transitSpaces = transitSpaces
        state = AutoFollowFocusState(pid: app.processIdentifier,
                                     startedAt: ProcessInfo.processInfo.systemUptime)
    }

    /// Rechecked immediately before AX writes as well as on each timer tick.
    var intentIsCurrent: Bool {
        gEnabled && gAutoFollowEnabled && !isNativeSwitchSpeed()
            && !app.isTerminated && !app.isHidden
            && inputCounts == autoFollowInputCounts()
    }
}

private var gAutoFollowFocusRequest: AutoFollowFocusRequest?

/// Abandons recovery when a physical gesture starts or a later follow wins.
/// Old scheduled callbacks compare request identity and become harmless.
func cancelAutoFollowFocusRepair() {
    gAutoFollowFocusRequest = nil
}

/// Only desktops on the target display and strictly between source and
/// destination can produce intermediate arrival activations belonging to us.
private func autoFollowTransitSpaces(to target: CGSSpaceID) -> Set<CGSSpaceID> {
    guard let connection = cgsMainConnection?(),
          let displays = cgsCopyDisplaySpaces?(connection, nil)?.takeRetainedValue()
              as? [[String: Any]] else { return [] }
    for display in displays {
        guard let spaces = display["Spaces"] as? [[String: Any]],
              let current = display["Current Space"] as? [String: Any],
              let source = (current["id64"] as? NSNumber)?.uint64Value else { continue }
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let start = ids.firstIndex(of: source), let end = ids.firstIndex(of: target),
              abs(end - start) > 1 else { continue }
        return Set(ids[(min(start, end) + 1)..<max(start, end)])
    }
    return []
}

/// Captures the frontmost normal window on the chosen destination before
/// posting the gesture. Windowless apps and All Desktops helpers keep their
/// native behavior; this repair never unminimizes or moves a window.
private func prepareAutoFollowFocusRepair(app: NSRunningApplication,
                                         space: CGSSpaceID) -> AutoFollowFocusRequest? {
    guard axWindowID != nil,
          let connection = cgsMainConnection?(),
          let spacesFor = slsCopySpacesForWindows,
          let windows = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]]
    else { return nil }

    for window in windows {
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
              let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let spaces = spacesFor(connection, kSLSSpaceTypeAll, [NSNumber(value: windowID)] as CFArray)?
                  .takeRetainedValue() as? [NSNumber],
              spaces.count == 1, spaces[0].uint64Value == space
        else { continue }
        return AutoFollowFocusRequest(app: app, space: space, windowID: windowID,
                                      transitSpaces: autoFollowTransitSpaces(to: space))
    }
    return nil
}

/// Tests the captured window again at repair time. A close, minimize, hide,
/// move to another Space or unknown window-server state cancels recovery.
private func followedWindowIsVisible(_ request: AutoFollowFocusRequest) -> Bool {
    guard getAllCurrentSpaces().contains(request.space),
          let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]],
          windows.contains(where: {
              ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == request.windowID
                  && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == request.app.processIdentifier
                  && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
          }),
          let connection = cgsMainConnection?(),
          let spaces = slsCopySpacesForWindows?(connection, kSLSSpaceTypeAll,
              [NSNumber(value: request.windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber]
    else { return false }
    return spaces.count == 1 && spaces[0].uint64Value == request.space
}

/// Uses Accessibility to focus only the captured window. In particular, do
/// not resurrect app.activate() / activateAllWindows: their Apple Event and
/// cross-Space side effects were removed for Picture-in-Picture in 6625f63.
private func restoreAutoFollowFocus(_ request: AutoFollowFocusRequest) {
    guard request.intentIsCurrent, followedWindowIsVisible(request),
          !isMissionControlActive(), let getWindowID = axWindowID,
          let displacedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          displacedPID != request.app.processIdentifier
    else { return }

    let application = AXUIElementCreateApplication(request.app.processIdentifier)
    guard AXUIElementSetMessagingTimeout(application, kAutoFollowAXTimeout) == .success else { return }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement]
    else { return }

    for window in windows {
        var windowID: CGWindowID = 0
        guard getWindowID(window, &windowID) == .success, windowID == request.windowID else { continue }
        guard AXUIElementSetMessagingTimeout(window, kAutoFollowAXTimeout) == .success else { return }
        var minimized: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
              (minimized as? Bool) == false,
              request.intentIsCurrent, followedWindowIsVisible(request),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == displacedPID
        else { return }

        guard AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString,
                                          kCFBooleanTrue) == .success,
              request.intentIsCurrent, followedWindowIsVisible(request)
        else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == displacedPID || frontmostPID == request.app.processIdentifier else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return
    }
}

/// Waits for arrival without imposing a fixed delay on every app switch.
private func checkAutoFollowFocus(_ request: AutoFollowFocusRequest) {
    guard gAutoFollowFocusRequest === request else { return }
    let action = request.state.step(
        now: ProcessInfo.processInfo.systemUptime,
        targetVisible: getAllCurrentSpaces().contains(request.space),
        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        inputUnchanged: request.intentIsCurrent)
    switch action {
    case .wait:
        DispatchQueue.main.asyncAfter(deadline: .now() + kAutoFollowFocusPollInterval) {
            checkAutoFollowFocus(request)
        }
    case .restore:
        cancelAutoFollowFocusRepair()
        restoreAutoFollowFocus(request)
    case .finish:
        cancelAutoFollowFocusRepair()
    }
}

/// Keeps an arrival-induced activation out of the regular auto-follow path.
/// New input invalidates the request even when it selects the same app that
/// macOS would have restored on arrival.
private func handleAutoFollowFocusActivation(_ app: NSRunningApplication) -> Bool {
    guard let request = gAutoFollowFocusRequest else { return false }
    let currentSpaces = getAllCurrentSpaces()
    return request.state.appActivated(
        app.processIdentifier, now: ProcessInfo.processInfo.systemUptime,
        targetVisible: currentSpaces.contains(request.space),
        inputUnchanged: request.intentIsCurrent,
        transitVisible: !request.transitSpaces.isDisjoint(with: currentSpaces))
}

// MARK: - Clicked-Window Detection

/// Whether the pointer currently sits inside one of the process's onscreen
/// windows, at any window layer.
///
/// Used to recognize activations caused by clicking a visible window of
/// the app. The clicked window is right where the user is, so no
/// navigation is needed — and native activation performs none either.
/// Layer-agnostic on purpose: the windows this matters for are exactly the
/// ones `findSpaceForPid`'s census cannot credit — Arc's floating video
/// popup sits at layer 3 and is assigned to every space, so it neither
/// counts as a normal window nor contributes a location as an anchored
/// one, and auto-follow would chase the app's main window on another
/// space, yanking the user away from the very thing they clicked.
///
/// - Parameter pid: The Unix process ID of the activated app.
/// - Returns: `true` when the pointer is inside one of its onscreen
///   windows.
private func pointerInsideOnscreenWindow(of pid: pid_t) -> Bool {
    // Global display coordinates (top-left origin), matching
    // kCGWindowBounds. A sourceless CGEvent reads the current pointer
    // position without an event tap.
    guard let location = CGEvent(source: nil)?.location,
          let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0)
              as? [[String: Any]]
    else { return false }

    for window in windows
    where (window["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid {
        // Fully transparent windows are invisible helpers (event-catching
        // overlays some apps park over the whole screen, offscreen
        // buffers); the user cannot have clicked what they cannot see, and
        // counting them would suppress wanted follows — e.g. a Dock click
        // landing "inside" an invisible overlay that happens to cover the
        // Dock. Semi-transparent windows still count.
        if ((window["kCGWindowAlpha"] as? NSNumber)?.doubleValue ?? 1) <= 0 {
            continue
        }

        guard let bounds = window["kCGWindowBounds"] as? [String: Any],
              let x = (bounds["X"]      as? NSNumber)?.doubleValue,
              let y = (bounds["Y"]      as? NSNumber)?.doubleValue,
              let w = (bounds["Width"]  as? NSNumber)?.doubleValue,
              let h = (bounds["Height"] as? NSNumber)?.doubleValue
        else { continue }

        if CGRect(x: x, y: y, width: w, height: h).contains(location) {
            return true
        }
    }
    return false
}

// MARK: - App Activation Observer

/// Watches for `NSWorkspace.didActivateApplicationNotification` and
/// auto-switches to the activated app's space when needed.
///
/// Registered in `main.swift` on the workspace notification center.
final class SwoopObserver: NSObject {

    /// Called whenever an application becomes active system-wide.
    ///
    /// - Parameter note: The notification containing the activated app info.
    @objc func appActivated(_ note: Notification) {
        guard gEnabled, gAutoFollowEnabled else { return }

        // At the "Normal" transition speed, macOS's own activation logic
        // already navigates to the app's space with the native animation —
        // exactly what the user asked for. Stand down.
        guard !isNativeSwitchSpeed() else { return }

        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        if handleAutoFollowFocusActivation(app) { return }

        // Echo of the follow we just performed for this very app — ignore it
        // (see kAutoFollowEchoWindow). Any other app activating means the
        // user moved on, so the echo window ends there and then.
        if pid == gLastFollowedPid {
            if Date().timeIntervalSince(gLastFollowedTime) <= kAutoFollowEchoWindow { return }
        } else {
            gLastFollowedPid = -1
        }

        // Suppress auto-follow when the user just navigated spaces themselves
        // (see kAutoFollowSuppressionWindow documentation above)
        guard Date().timeIntervalSince(gLastSpaceSwitchTime) > kAutoFollowSuppressionWindow
        else { return }

        // A hotkey from the user's ignore list just went by: this
        // activation is that hotkey's doing — an app summoned to open a
        // popup on the *current* space (Arc's Little Arc). The popup
        // window does not exist yet at notification time, so
        // findSpaceForPid would chase the app's main window on another
        // space and yank the user away from the popup they just summoned.
        // Stand down and let macOS's native handling take over.
        guard Date().timeIntervalSince(gLastHotkeyChordTime) > kAutoFollowIgnoredHotkeyWindow
        else { return }

        // A Mission Control overview handles navigation itself and our
        // gestures land back where they started — see isMissionControlActive()
        guard !isMissionControlActive() else { return }

        // A click just landed (either button) and the pointer sits inside
        // one of the activated app's onscreen windows: the user clicked a
        // visible window of this app — a floating video popup, a status
        // item, a palette. The clicked window is right where the user is;
        // native activation performs no navigation for it, and chasing
        // the app's other windows would yank the user away from the very
        // thing they clicked (see pointerInsideOnscreenWindow). The cheap
        // timing check runs first; the window scan only follows a fresh
        // click.
        let sinceClick = min(
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .rightMouseDown))
        if sinceClick < kAutoFollowClickWindow,
           pointerInsideOnscreenWindow(of: pid) {
            return
        }

        // Find which space the app's windows are on.
        // Returns 0 if the app is already on a visible space (no switch needed).
        let targetSpace = findSpaceForPid(pid)
        guard targetSpace != 0 else { return }

        let focusRequest = prepareAutoFollowFocusRepair(app: app, space: targetSpace)

        // Switch to the target space and record it for statistics.
        //
        // We intentionally do NOT call app.activate() after switching.
        // `NSRunningApplication.activate()` sends a kAEActivate Apple Event
        // to the target app, which some apps (e.g. Safari) interpret as
        // "user has brought me to the foreground" — causing them to exit
        // special background modes such as Picture-in-Picture.
        //
        // Native activation normally finishes the job. If arrival instead
        // reactivates the destination's previous app (#72), the bounded AX
        // repair below restores only the selected window, unless new input
        // or navigation has already superseded this follow.
        // .declined means macOS's native (animated) switch takes over —
        // nothing to record. .alreadyThere cannot normally happen here
        // since findSpaceForPid only returns non-visible spaces.
        if switchToSpace(targetSpace) == .switched {
            // Remember what we did: the PID so a repeat notification for the
            // same app reads as an echo, and the destination space so the
            // activeSpaceDidChange observer knows this change was ours and
            // does not stamp gLastSpaceSwitchTime for it (issue #24).
            gLastFollowedPid      = pid
            gLastFollowedTime     = Date()
            gAutoFollowTargetSpace = targetSpace

            gMenu?.recordSwitch()
            gAutoFollowFocusRequest = focusRequest
            if let focusRequest { checkAutoFollowFocus(focusRequest) }
        }
    }
}
