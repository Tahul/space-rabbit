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

// MARK: - Application Setup

// Clean up the per-app accent-color override written by older builds, so
// the app follows the user's system accent color everywhere.
UserDefaults.standard.removeObject(forKey: "AppleAccentColor")

let app = NSApplication.shared
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

// Check for updates 5 seconds after launch, giving the app
// time to settle before making a network request…
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { checkForUpdates() }

// …and once a day thereafter: the app typically runs for weeks between
// launches, so a single launch-time check would leave long-running
// instances unaware of new releases.
let updateCheckInterval: TimeInterval = 60 * 60 * 24
let updateCheckTimer = Timer.scheduledTimer(withTimeInterval: updateCheckInterval,
                                            repeats: true) { _ in checkForUpdates() }
updateCheckTimer.tolerance = updateCheckInterval / 10

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
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil, queue: .main
) { _ in gLastSpaceSwitchTime = Date() }

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
