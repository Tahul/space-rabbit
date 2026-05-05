# Guidelines For Agents

## Identity

- **App name:** Space Rabbit
- **Bundle ID:** `app.spacerabbit`
- **GitHub repo:** `Tahul/space-rabbit` (git@github.com:Tahul/space-rabbit.git)
- **Minimum macOS:** 13.0
- **Authors:** Yaël Guilloux (@tahul) and Valerian Saliou (@valeriansaliou)
- **Website:** https://space-rabbit.app

## What this project is

A macOS menu bar utility that removes the slide animation when switching Spaces (virtual desktops). It makes space transitions instant.

Multi-file Swift app in `App/` compiled with `swiftc` via a hand-written `Makefile`. No Xcode project, no SPM dependencies. `Package.swift` exists **only** for SourceKit-LSP (IDE code intelligence) — it is never used for building.

The app runs as an `LSUIElement` (no Dock icon, no app menu), living entirely in the menu bar.

## How it works

The core trick: macOS's Dock processes high-velocity `DockSwipe` gesture events and switches spaces immediately without animation when the velocity is high enough. Space Rabbit posts synthetic `CGEvent` pairs (Began + Ended) with extreme velocity/progress values directly into the session event tap, bypassing the normal animated space switch.

Technique borrowed from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher).

## Startup sequence (`main.swift`)

Exact initialization order — getting this wrong causes subtle bugs:

1. `NSApplication.shared.setActivationPolicy(.accessory)` — hide from Dock
2. **Accessibility check** — `AXIsProcessTrustedWithOptions` with prompt; exits if denied
3. `loadSpaceSwitchShortcuts()` — reads keycodes/modifiers from system prefs into `gKeyLeft`/`gKeyRight`/`gModMask`
4. `gMenu = SwoopMenu()` — creates status item, loads persisted state from UserDefaults into globals
5. Delayed `checkForUpdates()` — 5 seconds after launch (background network request)
6. `Timer` for `flushSwitchCount()` — every 300 seconds
7. **Event tap creation** — `CGEvent.tapCreate` → `CFMachPortCreateRunLoopSource` → `CFRunLoopAddSource`
8. **SwoopObserver registration** — `didActivateApplicationNotification` + `activeSpaceDidChangeNotification`
9. **Cleanup handler** — `willTerminateNotification`: flush stats, remove observer, disable tap
10. **Signal handlers** — SIGINT/SIGTERM → `NSApp.terminate`
11. `app.run()` — enter run loop

## Two core features

### Feature 1: Instant space switch (`eventTapCallback` in `EventTap.swift`)

A `CGEvent` tap at `.cgSessionEventTap` / `.headInsertEventTap` listens for `keyDown` events. When the user's configured modifier+arrow shortcut is detected:

1. The original key event is **swallowed** (callback returns `nil`).
2. `postSwitchGesture(direction:)` posts a Began+Ended gesture pair with high velocity.
3. The Dock handles the gesture and switches the space with no animation.

The tap is re-enabled on `tapDisabledByTimeout` / `tapDisabledByUserInput` to stay alive.

**Shortcut matching logic** in `eventTapCallback`:
- Extract `flags` and `keycode` from the event
- Check `flags.intersection(kRelevantModifiers) == gModMask` — ensures *exactly* the right modifiers (no extras)
- Match keycode against `gKeyLeft` (direction -1) or `gKeyRight` (direction +1)
- Bounds check via `getSpaceList()` — don't switch past the first/last space

### Feature 2: Auto-follow on Cmd+Tab (`SwoopObserver` in `AutoFollow.swift`)

Listens for `NSWorkspace.didActivateApplicationNotification`. When an app is activated:

1. **Suppression check** — skip if within `kAutoFollowSuppressionWindow` (300ms) of the last space switch
2. `findSpaceForPid(_:)` uses `visibleWindowSpaces(for:)` to find the app's window spaces, returns 0 if already reachable
3. `appWindowsConfinedToSpace(_:_:)` checks if `.activateAllWindows` is safe (no windows on other spaces)
4. `switchToSpace(_:)` computes direction + steps and posts that many gestures
5. After `kPostSwitchActivationDelay` (100ms), calls `app.activate(options:)`

### Feature interaction (suppression guard)

The two features suppress each other to prevent loops. After instant-switch fires, `gLastSpaceSwitchTime` is stamped. Auto-follow checks this timestamp and skips if within 300ms. The `activeSpaceDidChangeNotification` observer in `main.swift` also stamps this time for trackpad-initiated switches (which bypass the event tap entirely).

## Private APIs in use (`PrivateAPI.swift`)

### CGS functions (resolved via `loadSymbol()` / `dlsym` at startup)

| C symbol | Swift variable | Signature | Purpose |
|---|---|---|---|
| `CGSMainConnectionID` | `cgsMainConnection` | `() -> Int32` | Current session's connection ID |
| `CGSGetActiveSpace` | `cgsGetActiveSpace` | `(cid) -> UInt64` | Active space ID on main display |
| `CGSCopyManagedDisplaySpaces` | `cgsCopyDisplaySpaces` | `(cid, displayUUID?) -> CFArray?` | All displays + their spaces |
| `SLSCopySpacesForWindows` | `slsCopySpacesForWindows` | `(cid, spaceType, windowIDs) -> CFArray?` | Maps window IDs → space IDs |

If any symbol is missing (Apple renamed it), the variable is `nil` and dependent features gracefully no-op.

### CGSCopyManagedDisplaySpaces dictionary structure

This is parsed in `getSpaceList()`, `getAllCurrentSpaces()`, and `switchToSpace()`:

```
[                                    // CFArray of display dictionaries
  {
    "Current Space": {               // currently active space on this display
      "id64": 42 as UInt64,          // << the space ID we care about
      "type": 0,
      ...
    },
    "Spaces": [                      // ordered list of all spaces on this display
      { "id64": 42, "type": 0, ... },
      { "id64": 43, "type": 0, ... },
      ...
    ],
    "Display Identifier": "...",
    ...
  },
  ...  // one entry per connected display
]
```

Key: `"id64"` is cast to `UInt64` via `(space["id64"] as? NSNumber)?.uint64Value`.

### Synthetic gesture event anatomy

Each space switch requires posting **two gesture pairs** (Began + Ended). Each pair consists of two `CGEvent` objects posted back-to-back:

**Event 1 — Generic gesture envelope:**
- `kCGSEventTypeField` (field 55) = `kCGSEventGesture` (29)

**Event 2 — Dock control payload:**
- `kCGSEventTypeField` (55) = `kCGSEventDockControl` (30)
- `kCGEventGestureHIDType` (110) = `kIOHIDEventTypeDockSwipe` (23)
- `kCGEventGesturePhase` (132) = Began (1) or Ended (4)
- `kCGEventScrollGestureFlagBits` (135) = 0 (left) or 1 (right)
- `kCGEventGestureSwipeMotion` (123) = 1
- `kCGEventGestureScrollY` (119) = 0.0
- `kCGEventGestureZoomDeltaX` (139) = `Float.leastNonzeroMagnitude` (non-zero epsilon so the Dock doesn't discard it)
- *(Ended phase only:)*
  - `kCGEventGestureSwipeProgress` (124) = ±2.0 (`kInstantSwitchProgress`)
  - `kCGEventGestureSwipeVelocityX` (129) = ±400.0 (`kInstantSwitchVelocity`)
  - `kCGEventGestureSwipeVelocityY` (130) = 0.0

Post order: dock event first, then gesture envelope. Both go to `.cgSessionEventTap`.

### Symbolic hotkeys (`Shortcuts.swift`)

Read from `CFPreferencesCopyAppValue("AppleSymbolicHotKeys", "com.apple.symbolichotkeys")`.

| Hotkey ID | Meaning | Constant |
|---|---|---|
| `"79"` | Move left a space | `kHotkeyMoveLeftSpace` |
| `"81"` | Move right a space | `kHotkeyMoveRightSpace` |

Entry structure: `{ enabled: Bool/Int, value: { parameters: [unused, keycode, carbonMods], type: "standard" } }`. Keycode 65535 = empty slot. Carbon modifier bits decoded via `CarbonModifier` enum (shift=0x020000, control=0x040000, option=0x080000, command=0x100000).

## Window filtering criteria

Used in `visibleWindowSpaces(for:)` — the shared helper for both `findSpaceForPid` and `appWindowsConfinedToSpace`:

1. `kCGWindowOwnerPID` must match the target PID
2. `kCGWindowLayer` must be 0 (normal windows only — excludes menus, tooltips, status items)
3. `kCGWindowIsOnscreen` must be 1 (excludes minimized/hidden windows)
4. `SLSCopySpacesForWindows(cid, 7, [windowID])` must return a non-zero space ID
   - The magic `7` = `kSLSSpaceTypeAll` (all space types: user, fullscreen, etc.)

## Global state (`State.swift`)

All runtime state is module-level globals (not a singleton class). This is intentional: single-threaded app, no concurrency beyond the main thread.

| Variable | Type | Purpose |
|---|---|---|
| `gTap` | `CFMachPort?` | The active CGEvent tap |
| `gEnabled` | `Bool` | Master on/off toggle |
| `gInstantSwitchEnabled` | `Bool` | Feature 1 toggle |
| `gAutoFollowEnabled` | `Bool` | Feature 2 toggle |
| `gSoundsEnabled` | `Bool` | Play sound on master toggle |
| `gLastSpaceSwitchTime` | `Date` | For auto-follow suppression (initialized to `.distantPast`) |
| `gSwitchCount` | `Int` | Lifetime switch counter (persisted periodically) |
| `gSwitchCountSaved` | `Int` | Last persisted value (avoids redundant writes) |
| `gKeyLeft` / `gKeyRight` | `Int64` | Keycodes (default: 123/124 = arrow keys) |
| `gModMask` | `CGEventFlags` | Modifier mask (default: `.maskControl`) |
| `gMenu` | `SwoopMenu?` | The menu bar status item instance |

### UserDefaults keys (`Defaults` enum)

`spacerabbit.enabled`, `spacerabbit.instantSwitch`, `spacerabbit.autoFollow`, `spacerabbit.sounds`, `spacerabbit.switchCount`.

Persistence strategy: `flushSwitchCount()` writes to disk only if `gSwitchCount != gSwitchCountSaved`. Called every 300s by timer and once on app termination. Acceptable to lose a few counts on crash.

## Key named constants

| Constant | File | Value | Purpose |
|---|---|---|---|
| `kSLSSpaceTypeAll` | SpaceSwitching | `7` (Int32) | Bitmask for "all space types" in SLS calls |
| `kInstantSwitchProgress` | SpaceSwitching | `2.0` | Fully-committed swipe progress |
| `kInstantSwitchVelocity` | SpaceSwitching | `400.0` | Velocity above Dock's instant threshold |
| `kAutoFollowSuppressionWindow` | AutoFollow | `0.3` (TimeInterval) | Grace period before auto-follow kicks in |
| `kPostSwitchActivationDelay` | AutoFollow | `0.1` (TimeInterval) | Delay before activating app windows |
| `kRelevantModifiers` | EventTap | Control/Cmd/Alt/Shift | Modifier keys checked when matching shortcuts |
| `kMenuIconSize` | MenuBar | `16` (CGFloat) | Tinted SF Symbol size in menu items |
| `kDisabledIconAlpha` | MenuBar | `0.25` (CGFloat) | Menu bar icon opacity when disabled |
| `ToggleColors.disable` | MenuBar | coral red | Color for "Disable" button icon |
| `ToggleColors.enable` | MenuBar | teal green | Color for "Enable" button icon |
| `Layout.*` | Settings | various | All spacing/sizing/padding for preferences window |
| `CarbonModifier.*` | Shortcuts | hex bitmasks | Legacy Carbon modifier flag values |
| `kHotkeyMoveLeftSpace` | Shortcuts | `"79"` | System hotkey ID for left-space |
| `kHotkeyMoveRightSpace` | Shortcuts | `"81"` | System hotkey ID for right-space |

## Update flow (`UpdateCheck.swift` + `UpdateInstall.swift`)

### Version checking

Two entry points in `UpdateCheck.swift`:
- **Automatic** (`checkForUpdates()`): fires 5 s after launch, silently shows the menu bar banner if a newer release exists.
- **Manual** (`checkForUpdatesManually()`): triggered from the "Check for Updates…" menu item, reports results via callbacks so the caller can show dialogs.

Both hit `GET /repos/Tahul/space-rabbit/releases/latest` on the GitHub API, extract the `tag_name` and the first `.dmg` asset URL, and compare against `CFBundleShortVersionString`.

### Download and installation

`UpdateInstall.swift` contains `UpdaterWindowController`, a singleton that manages the full install flow:

1. **Download** — A `URLSession` download task fetches the DMG to `NSTemporaryDirectory()/SpaceRabbitUpdate.dmg`. Progress is shown in a small non-modal window with a cancel button.
2. **Mount** — `hdiutil attach -nobrowse -noautoopen` mounts the DMG. The `/Volumes/…` mount point is parsed from `hdiutil`'s tab-separated stdout.
3. **Stage** — The `.app` inside the volume is copied to `Space Rabbit.staged.app` next to the running bundle (same volume = cheap copy).
4. **Swap** — `FileManager.replaceItemAt` atomically replaces the running bundle with the staged copy (POSIX rename semantics — never half-written).
5. **Cleanup** — `hdiutil detach -force` unmounts the volume; the temp DMG is deleted.
6. **Restart** — An alert offers "Restart Now" or "Later". Restart spawns a detached `/bin/sh` that sleeps 0.5 s (waits for the process to exit) then `open`s the updated bundle.

Cancellation is allowed during download but blocked once file writes begin (`isInstalling` flag). On failure, an alert offers "Try Again" (restarts from step 1 with the same URL) or "Cancel" (leaves the menu bar banner visible for a later retry).

### Triggering the install

The install can be triggered from two places:
- Clicking the "Update Available · Click to Install" banner in the menu bar dropdown (`SwoopMenu.openDownloadURL`)
- Clicking "Install Now" in the dialog shown by `SwoopMenu.handleCheckForUpdates`

Both call `startUpdate(downloadURL:)` which delegates to `UpdaterWindowController.shared.start(downloadURL:)`.

## Data flow: toggle state changes

Toggles can be changed from two places. The sync pattern:

1. **Menu bar** → `SwoopMenu.toggleInstantSwitch`/`toggleAutoFollow`: writes `gXxxEnabled` → `UserDefaults` → updates menu checkmark
2. **Settings window** → `GeneralViewController.toggleInstantSwitch`/`toggleAutoFollow`: writes `gXxxEnabled` → `UserDefaults` → calls `gMenu?.syncMenuItems()` to sync menu checkmarks
3. **Settings window opens** (`viewWillAppear`): refreshes all switch controls from globals

Master enable/disable (`gEnabled`) is only togglable from the menu bar (menu item or right-click).

### The NSStatusItem right-click trick

`NSStatusItem` can have either a `.menu` or a `.button.action`, not both simultaneously. To support left-click (open menu) and right-click (quick toggle):

1. Button is configured with `sendAction(on: [.leftMouseUp, .rightMouseUp])` and a target action
2. On right-click: toggle `gEnabled` directly
3. On left-click: temporarily set `statusItem.menu = statusMenu`, call `performClick`, then set `statusItem.menu = nil`

This is in `SwoopMenu.statusItemClicked(_:)`.

## UI structure

```
SwoopMenu (NSStatusItem, icon: "hare.fill")
  └─ NSMenu
       ├─ Update-available banner (hidden by default, shown by checkForUpdates)
       ├─ Launch-at-login warning banner (hidden when SMAppService.mainApp.status == .enabled)
       ├─ Enable/Disable toggle (icon changes between green checkmark / red X)
       ├─ "Configure:" section header
       ├─ Instant space switch toggle (checkmark, shortcut: S)
       ├─ Auto-follow on ⌘⇥ toggle (checkmark, shortcut: F)
       ├─ "Statistics:" section header
       ├─ Switch count + time-saved display (non-interactive)
       ├─ Version label
       ├─ Preferences… (shortcut: ,) → SettingsWindowController.shared.show()
       └─ Quit (shortcut: Q)

SettingsWindowController (singleton, NSWindowDelegate)
  └─ PreferencesTabViewController (NSTabViewController, .toolbar style)
       ├─ GeneralViewController
       │    ├─ Launch warning banner (orange, hidden when OK)
       │    ├─ "Auto-start" section: Launch at Login (SMAppService)
       │    ├─ "Features" section: Instant switch + Auto-follow
       │    ├─ "Interface" section: Enable sounds
       │    └─ "Advanced" section: Instant Dock hide (writes com.apple.dock autohide-time-modifier, killall Dock)
       └─ AboutViewController
            ├─ App icon + name + version + copyright
            ├─ Website link (space-rabbit.app)
            ├─ Author links (github.com/tahul, valeriansaliou.name)
            └─ Manual-update notice box
```

Custom controls: `LinkTextField` / `LinkButton` — subclasses that override `resetCursorRects()` to show a pointing-hand cursor.

### Dock instant-hide feature (GeneralViewController)

Writes `autohide-time-modifier` to `com.apple.dock` preferences:
- Enable: set to `0.0` (instant)
- Disable/reset: remove the key (restore system default)
- Requires `CFPreferencesAppSynchronize` + `killall Dock` to take effect
- Shows a confirmation alert before restarting the Dock
- "Reset to system default" link appears when the key is overridden

## Build system

Everything goes through the `Makefile`. No Xcode project.

| Target | What it does |
|---|---|
| `make build` | Compiles `App/*.swift` → `spacerabbit` binary |
| `make icon` | Regenerates `Icon/AppIcon.icns` from `Icon/CreateIcon.swift` |
| `make app` | `build` + assembles `Space Rabbit.app` bundle + code-signs |
| `make app-dev` | `app` + kills any running instance + relaunches — **use this during development** |
| `make dmg` | `app` + creates `Space-Rabbit.dmg` with Applications symlink |
| `make notarize` | Submits DMG to Apple notarytool and staples the ticket |
| `make release` | `dmg` + `notarize` in sequence |
| `make clean` | Removes binary, icns, and app bundle |

**During development, always use `make app-dev VERSION=0.0.0`** — the `VERSION=0.0.0` ensures the version is lower than any published release so the update checker never prompts. This target builds, kills the running instance, and relaunches in one step.

**Compiler flags:** `swiftc -O` (optimized). Linked frameworks: CoreGraphics, CoreFoundation, ApplicationServices, AppKit, ServiceManagement.

**Version flow:** `git describe --tags --abbrev=0` → strips `v` prefix → `sed` replaces `__VERSION__` in `Info.plist` → app reads it at runtime via `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`.

**Signing:** credentials in `local.env` (git-ignored): `SIGN_ID`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. If `SIGN_ID` is empty, `make app` prompts interactively (or skips signing).

## Project layout

```
App/
  main.swift            — entry point: permissions, event tap, observers, run loop
  PrivateAPI.swift      — undocumented CGEvent fields, CGS types, dlsym resolution
  State.swift           — global runtime state, UserDefaults keys, persistence
  Shortcuts.swift       — reads macOS space-switch keyboard shortcuts
  SpaceSwitching.swift  — space queries, synthetic gesture posting, navigation
  EventTap.swift        — CGEvent tap callback (Feature 1: instant switch)
  AutoFollow.swift      — app-activation observer (Feature 2: auto-follow)
  MenuBar.swift         — SwoopMenu status item and dropdown menu
  Settings.swift        — preferences window (General + About tabs) — largest file
  UpdateCheck.swift     — GitHub release version checking
  UpdateInstall.swift   — automatic update download, DMG install, and restart
  Info.plist            — bundle metadata (version placeholder: __VERSION__)
Icon/
  AppIcon.icns          — compiled icon (git-ignored, regenerated by `make icon`)
  CreateIcon.swift      — generates the icns programmatically
Makefile
Package.swift           — LSP stub only, NOT used for building
README.md
CLAUDE.md               — this file
local.env               — git-ignored; signing credentials
.gitignore              — ignores .app, .dmg, binary, .build/, local.env, icons
```

## Coding conventions

- **Globals prefixed `g`** — all mutable runtime state (e.g. `gEnabled`, `gTap`). Single-threaded app, no locks needed.
- **Constants prefixed `k`** — named magic numbers (e.g. `kSLSSpaceTypeAll`, `kInstantSwitchVelocity`).
- **Enums for grouping constants** — `Defaults` (UserDefaults keys), `CarbonModifier` (bitmasks), `Layout` (UI sizing), `ToggleColors`.
- **`MARK` sections** — every file uses `// MARK: -` with descriptive headers.
- **Doc comments** — `///` with `- Parameter:` and `- Returns:` annotations on all public/internal functions.
- **Private API isolation** — all undocumented symbols confined to `PrivateAPI.swift`. Other files use typed function pointers and named constants.
- **UI built programmatically** — no nibs, storyboards, or SwiftUI. All views use `NSStackView` + Auto Layout.
- **C-compatible callbacks** — `eventTapCallback` and `onSignal` are global functions (not methods/closures) because their APIs require C function pointers.

## Known limitations

- Trackpad swipe gestures still animate (they bypass the event tap entirely).
- Finder without open windows always animates to the first space — native behavior.
- Cmd+Tab to fullscreen apps may briefly flicker.
- Uses undocumented CGEvent fields and private CGS symbols — may break on macOS updates.
