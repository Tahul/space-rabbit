/*
 * main.swift — Space Rabbit entry point
 *
 * This is the application entry point. It:
 *   1. Checks for Accessibility permissions (required for the event tap)
 *   2. Loads the user's space-switch keyboard shortcuts
 *   3. Creates the menu bar UI
 *   4. Installs the CGEvent tap for instant space switching
 *   5. Registers the app-activation observer for auto-follow
 *   6. Schedules periodic persistence and runs the main event loop
 *
 * Space Rabbit runs as an "accessory" app (no Dock icon, no app menu),
 * living entirely in the menu bar.
 */

import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - Application Delegate

/// Handles launch and reopen (user launches Space Rabbit while it is
/// already running).
///
/// Needed when the menu bar icon is hidden: there is otherwise no UI entry
/// point. Opening the app again from Spotlight or Finder surfaces Preferences.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If the menu bar icon is hidden and the user launched the app
        // manually (not as a login item), open Preferences so they still
        // have a way in. This must run here — not in top-level code — since
        // the launch Apple event is only current while it is dispatched,
        // which happens during finishLaunching.
        if gMenu?.isMenuBarIconVisible == false, !isLaunchedAsLoginItem() {
            SettingsWindowController.shared.show(pane: .advanced)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Deep-link to the Advanced pane (where the icon toggle lives) only
        // when the icon is hidden; otherwise open the default pane.
        let pane: SettingsPane? = gMenu?.isMenuBarIconVisible == false ? .advanced : nil
        SettingsWindowController.shared.show(pane: pane)
        return false
    }
}

// MARK: - Login Item Detection

/// Returns `true` when this process was started as a login item.
///
/// Used so a hidden menu bar icon does not pop Preferences at every login,
/// while a manual launch of the app still opens Preferences as the recovery path.
///
/// Only valid while the launch Apple event is being dispatched (i.e. from
/// `applicationDidFinishLaunching`); before `app.run()` it always returns `false`.
private func isLaunchedAsLoginItem() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
    guard event.eventID == AEEventID(kAEOpenApplication) else { return false }
    guard let propData = event.paramDescriptor(forKeyword: keyAEPropData) else { return false }
    return propData.enumCodeValue == AEKeyword(keyAELaunchedAsLogInItem)
}

// MARK: - Application Setup

// Clean up the per-app accent-color override written by older builds, so
// the app follows the user's system accent color everywhere.
UserDefaults.standard.removeObject(forKey: "AppleAccentColor")

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)

// MARK: - Accessibility Permission Check
//
// The CGEvent tap requires Accessibility access. Without it, the tap
// cannot be created and the app is useless. We prompt once and exit
// if permission is not granted.

let trustedCheckOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
guard AXIsProcessTrustedWithOptions(trustedCheckOptions as CFDictionary) else {
    fputs("Space Rabbit: accessibility permission required\n", stderr)
    fputs("  Grant in: System Settings > Privacy & Security > Accessibility\n", stderr)
    exit(1)
}

// MARK: - Initialization

// Load the user's configured space-switch keyboard shortcuts
// from macOS system preferences (e.g. Control+Arrow, Option+Arrow)
loadSpaceSwitchShortcuts()

// Create the menu bar status item and load persisted preferences
// (switch count, feature toggles, etc.) from UserDefaults
gMenu = SwoopMenu()

// Check for updates 5 seconds after launch, giving the app time to
// settle before making a network request. Launch-only by design: no
// periodic background re-check (a manual check lives in the settings
// window's Updates pane). Throttled to at most one check per hour, so
// a quick quit-and-relaunch cycle does not re-hit the API each time.
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { checkForUpdates() }

// Persist the switch count to disk every 5 minutes.
// This batching reduces disk I/O compared to writing on every switch.
// The count is also flushed on termination (see cleanup section below).
let flushInterval: TimeInterval = 300
Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { _ in
    flushSwitchCount()
}

// MARK: - Event Tap Installation
//
// The event tap intercepts keyDown events at the session level.
// When a space-switch shortcut is detected, the original event is
// swallowed and replaced with a synthetic DockSwipe gesture.

let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

gTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: eventTapCallback,
    userInfo: nil
)

guard let tap = gTap else {
    fputs("Space Rabbit: failed to create event tap\n", stderr)
    exit(1)
}

guard let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
    fputs("Space Rabbit: failed to create run loop source\n", stderr)
    exit(1)
}

CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Install the swipe-intercept tap (Feature 3) if the feature is enabled.
// Must come after gMenu is created — it reads the persisted toggles.
// Unlike the keyboard tap above, this one is torn down and re-created as
// the feature is toggled, so a creation failure here is not fatal.
updateSwipeTap()

// MARK: - App Activation Observer (Auto-Follow)
//
// Listens for app-activation events (Cmd+Tab, Dock click, etc.)
// and switches to the activated app's space if it's not already visible.

let observer = SwoopObserver()
NSWorkspace.shared.notificationCenter.addObserver(
    observer,
    selector: #selector(SwoopObserver.appActivated(_:)),
    name: NSWorkspace.didActivateApplicationNotification,
    object: nil
)

// Also stamp the switch time on any space change (covers trackpad swipes,
// which bypass the event tap entirely). This notification arrives before
// the app activation notification, so the auto-follow suppression guard
// fires correctly for trackpad-initiated switches too.
//
// Exception: a change auto-follow itself asked for is not the user
// navigating. This notification lands only once the transition has settled
// (hundreds of milliseconds later), so stamping it would hold auto-follow
// suppressed well past kAutoFollowSuppressionWindow and let macOS animate
// the user's next quick Cmd+Tab (issue #24).
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil, queue: .main
) { _ in
    // A multi-step follow reports intermediate spaces first; only the
    // notification that actually lands on the destination counts as ours
    // and retires the record. Anything older than the grace window is
    // treated as a switch that never landed.
    if gAutoFollowTargetSpace != 0,
       Date().timeIntervalSince(gLastFollowedTime) <= kAutoFollowSelfChangeWindow,
       getAllCurrentSpaces().contains(gAutoFollowTargetSpace) {
        gAutoFollowTargetSpace = 0
        return
    }

    gLastSpaceSwitchTime = Date()
}

// Reload the space-switch shortcuts whenever System Settings deactivates —
// the only place the user can edit them. Without this, shortcut changes
// would only be picked up at the next launch. (Changes made behind the
// scenes, e.g. via `defaults write`, still require a relaunch.)
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didDeactivateApplicationNotification,
    object: nil, queue: .main
) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
          app.bundleIdentifier == "com.apple.systempreferences" else { return }
    loadSpaceSwitchShortcuts()
}

// MARK: - Cleanup on Exit
//
// Flush stats to disk and tear down the event tap when the app terminates.
// This ensures we don't lose switch count data and cleanly remove
// ourselves from the event tap chain.

NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil, queue: .main
) { _ in
    flushSwitchCount()
    NSWorkspace.shared.notificationCenter.removeObserver(observer)
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    if let swipeTap = gSwipeTap { CGEvent.tapEnable(tap: swipeTap, enable: false) }
}

// MARK: - Signal Handling
//
// Gracefully terminate on SIGINT/SIGTERM so the cleanup handler runs.
// Without this, a `kill` or Ctrl+C would skip the willTerminate notification.
//
// A plain signal() handler may only call async-signal-safe functions —
// dispatch and AppKit are not — so the signals are ignored at the process
// level and observed via DispatchSource on the main queue instead.

signal(SIGINT,  SIG_IGN)
signal(SIGTERM, SIG_IGN)

let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

// MARK: - Run

print("Space Rabbit: running")
app.run()
