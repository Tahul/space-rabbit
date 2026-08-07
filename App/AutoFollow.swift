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

        // A Mission Control overview handles navigation itself and our
        // gestures land back where they started — see isMissionControlActive()
        guard !isMissionControlActive() else { return }

        // Find which space the app's windows are on.
        // Returns 0 if the app is already on a visible space (no switch needed).
        let targetSpace = findSpaceForPid(pid)
        guard targetSpace != 0 else { return }

        // Switch to the target space and record it for statistics.
        //
        // We intentionally do NOT call app.activate() after switching.
        // `NSRunningApplication.activate()` sends a kAEActivate Apple Event
        // to the target app, which some apps (e.g. Safari) interpret as
        // "user has brought me to the foreground" — causing them to exit
        // special background modes such as Picture-in-Picture.
        //
        // This is unnecessary: the system activation already in progress
        // (from Cmd+Tab or Dock click that triggered this notification)
        // brings the app and its frontmost window to focus. Our space
        // switch is the only missing piece.
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
        }
    }
}
