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
private let kAutoFollowSuppressionWindow: TimeInterval = 0.3

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

        // Suppress auto-follow when instant-switch just fired
        // (see kAutoFollowSuppressionWindow documentation above)
        guard Date().timeIntervalSince(gLastSpaceSwitchTime) > kAutoFollowSuppressionWindow
        else { return }

        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }

        // Find which space the app's windows are on.
        // Returns 0 if the app is already on a visible space (no switch needed).
        let targetSpace = findSpaceForPid(app.processIdentifier)
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
        switchToSpace(targetSpace)
        gMenu?.recordSwitch()
    }
}
