/*
 * EmptySpaceGuard.swift — Stay on an empty Space after landing on it
 *
 * Landing on a Space with no windows makes macOS pick some other app and
 * activate it. When that app's key window lives on another Space, ordering
 * it in trips the Dock's window-order follow rule and the user is yanked
 * to that Space a few hundred milliseconds after arriving (issue #49).
 * Plain native switching does the same; the instant switch only makes the
 * round trip more visible.
 *
 * The fix removes the cause instead of disabling the Dock's follow rule
 * (`workspaces-auto-swoosh`), which would also kill Dock-icon-follow: the
 * moment we land on a Space with no ordinary window, Space Rabbit takes
 * activation itself. It has no windows to order in, so the follow never
 * fires. macOS still activates its pick, but too late to win.
 *
 * Technique and measurements from noswoosh (MIT,
 * https://github.com/mmathys/noswoosh): 3/3 yanks without the guard and
 * 0/3 with it on macOS 26.6, 8/8 and 0/8 on macOS 27.0. Activating Finder
 * instead does not work (it yanks to Finder's own window), and neither
 * does activating before the switch (the landing re-activates macOS's pick).
 * It must be a windowless app, on landing — which is why the app has to
 * stay `.accessory`: a `.prohibited` app cannot become active.
 */

import AppKit

/// Whether any ordinary window (layer 0) is resident on the given space.
///
/// Desktop elements (wallpaper, desktop icons) are excluded: they exist on
/// every Space and are not something macOS would focus on landing.
///
/// - Parameters:
///   - space: The space to inspect.
///   - cid: The main CGS connection.
///   - spacesFor: The resolved `SLSCopySpacesForWindows` function.
/// - Returns: `true` if at least one layer-0 window lives on `space`.
private func spaceHasNormalWindow(_ space: CGSSpaceID,
                                  cid: CGSConnectionID,
                                  spacesFor: FnSpacesForWindows) -> Bool {
    guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], 0)
            as? [[String: Any]] else { return true }

    let windowIDs = windowList.compactMap { window -> NSNumber? in
        guard ((window["kCGWindowLayer"] as? NSNumber)?.int32Value ?? -1) == 0 else { return nil }
        return window[kCGWindowNumber as String] as? NSNumber
    }
    guard !windowIDs.isEmpty else { return false }

    guard let spaces = spacesFor(cid, kSLSSpaceTypeAll, windowIDs as CFArray)?
            .takeRetainedValue() as? [NSNumber]
    else { return true }

    return spaces.contains { $0.uint64Value == space }
}

/// Takes activation when the user just landed on a Space with no windows,
/// so macOS cannot yank them away to another Space (issue #49).
///
/// Called from the `activeSpaceDidChangeNotification` observer in
/// `main.swift`, synchronously: the yank follows the landing by roughly
/// 400ms, and a notification observer has been measured to win that race
/// with ~380ms to spare.
///
/// Any failure to read the window layout reads as "not empty", which keeps
/// today's behavior.
func guardEmptySpaceLanding() {
    guard gEnabled,
          let mainConn  = cgsMainConnection,
          let getActive = cgsGetActiveSpace,
          let spacesFor = slsCopySpacesForWindows else { return }

    let cid = mainConn()
    guard cid != 0 else { return }

    let active = getActive(cid)
    guard active != 0, !spaceHasNormalWindow(active, cid: cid, spacesFor: spacesFor) else { return }

    NSApp.activate(ignoringOtherApps: true)
}
