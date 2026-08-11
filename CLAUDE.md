# Guidelines For Agents

## Identity

- **App name:** Space Rabbit
- **Bundle ID:** `app.spacerabbit`
- **GitHub repo:** `Tahul/space-rabbit` (git@github.com:Tahul/space-rabbit.git)
- **Minimum macOS:** 15.0
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

1. `app.delegate = AppDelegate()` — reopen handler (relaunching the app shows Preferences — the recovery path when the menu bar icon is hidden, deep-linking to the Advanced pane in that case). `applicationDidFinishLaunching` also opens Preferences when the icon is hidden and the launch was manual — login-item launches are exempted via `isLaunchedAsLoginItem()`, which reads the launch Apple event's `keyAELaunchedAsLogInItem` flag. That check is only valid while the launch event is current (inside `finishLaunching`) — it must NOT be called from top-level `main.swift` code, where it always returns false.
2. `NSApplication.shared.setActivationPolicy(.accessory)` — hide from Dock
3. **Accessibility check** — `AXIsProcessTrustedWithOptions` with prompt; exits if denied
4. `loadSpaceSwitchShortcuts()` — reads keycodes/modifiers from system prefs into `gKeyLeft`/`gKeyRight`/`gModMask`
5. `gMenu = SwoopMenu()` — creates status item (hidden via `statusItem.isVisible` if so configured), loads persisted state from UserDefaults into globals
6. `checkForUpdatesAutomatically()` — owns its own 5-second delay, and applies it only when it is actually going to make a network request (a throttled launch restores the update banner from UserDefaults immediately). Must run after step 5, which creates `gMenu`, the banner's host
7. `Timer` for `flushSwitchCount()` — every 300 seconds
8. **Event tap creation** — `installEventTap()` (EventTap.swift) creates `gTap` (listens for `keyDown` only, source stored in `gTapSource`). `installAuxiliaryKeyboardTaps()` immediately adds the two on-demand companions carrying the other three event forms the cycle shortcut (including bare Fn) and the system Space bindings need — see "Three keyboard taps" under Feature 1. Failure of the primary tap is fatal; failure of an auxiliary one is logged and tolerated
9. **Gesture-intercept tap** — `updateSwipeTap()` installs the shared tap pair if either persisted gesture toggle is on (must run after step 5, which loads the toggles; creation failure is non-fatal, unlike step 8)
10. **SwoopObserver registration** — `didActivateApplicationNotification` + `activeSpaceDidChangeNotification`
11. **Tap revival observers** — `NSWorkspace.didWakeNotification` + distributed `com.apple.screenIsUnlocked` → `reviveKeyboardTapsIfNeeded()` + `reviveSwipeTapIfNeeded()` (see "Event tap lifetime" under Feature 1); the step 7 timer runs the same checks as a safety net
12. **Cleanup handler** — `willTerminateNotification`: flush stats, remove the three observers (`SwoopObserver`'s, plus the two revival ones from step 11 — the wake one via `NSWorkspace`, the unlock one via `DistributedNotificationCenter`), disable both taps
13. **Signal handlers** — SIGINT/SIGTERM → `NSApp.terminate`
14. `app.run()` — enter run loop

## Core features

### Feature 1: Instant space switch (`eventTapCallback` in `EventTap.swift`)

A `CGEvent` tap at `.cgSessionEventTap` / `.headInsertEventTap` listens for `keyDown` events. When the user's configured modifier+arrow shortcut is detected:

1. The original key event is **swallowed** (callback returns `nil`).
2. `postSwitchGesture(direction:)` posts a Began+Ended gesture pair using the
   global transition velocity.
3. The Dock handles the gesture at the selected speed (with no animation at
   the Instant tick).

**Event tap lifetime:** the tap is re-enabled on `tapDisabledByTimeout` / `tapDisabledByUserInput` to stay alive — but those notices arrive *through the tap callback itself*, so a tap disabled (or its Mach port invalidated) while the process is suspended around system sleep or screen lock never self-heals. `reviveKeyboardTapsIfNeeded()` (EventTap.swift) and `reviveSwipeTapIfNeeded()` (SwipeIntercept.swift) cover that hole for all five taps: re-enable a valid-but-disabled tap, rebuild on an invalidated Mach port, and refresh the cached `g*TapEnabled` flags of the on-demand taps (a stale cache pins them dead, because the sync helpers only push state on a flag change). They run on `NSWorkspace.didWakeNotification`, on the distributed `com.apple.screenIsUnlocked` notification, and from the 300 s flush timer as a safety net; each revival logs a diagnostic line to stderr.

A failed *rebuild* is deliberately **not** fatal, unlike the same failure at startup — quitting a menu bar app out from under the user is worse than staying up and retrying on the next wake, unlock or health check. Revoked Accessibility permission is the one cause the user can act on and the stderr line is their only signal, so the diagnostic names it explicitly (`AXIsProcessTrusted()`), and logs only on the transition into the failed state so a permanently-revoked Mac doesn't write the same line twelve times an hour.

**Recovery discards in-flight gesture state**, on purpose. Both revival helpers reset their per-gesture tracking before touching a tap, because state from before the break must not leak into the next gesture — and in the keyboard case, a claim only ever outlives one keystroke when its tap is already dead. Two consequences worth knowing: dropping a claimed press releases the `keyUp` Space Rabbit still owed macOS, so the frontmost app sees a release with no press (the safe direction — the alternative is a modifier it believes is still held); and a held vertical prefix is discarded without replay, since replay goes through the tap proxy of a tap that no longer exists. The latter costs one swallowed gesture, not a half-open Dock gesture — a held prefix is the *physical* Began that never reached Dock. A synthetic stream already in flight is unaffected either way: the animator posts its terminal pair from its own serial queue straight to the session tap, never through these taps.

**Three keyboard taps.** The feature needs four event forms, but only `keyDown`
can ever *match* a shortcut; the other three exist to close out a press that
already matched. They are split the same way, and for the same reason, as the
gesture taps (see Feature 3): a `.defaultTap` costs a synchronous round-trip
through this process per subscribed event, so a type that only matters inside a
narrow window is not subscribed to outside it. Measured while typing on macOS
26 — 127 `keyDown`, 127 `keyUp`, 6 `flagsChanged`, 0 `systemDefined` over 25 s,
so the split removes 51% of the wakeups:

- `gTap` — `keyDown`. Installed once at startup, never torn down.
- `gClaimedKeyTap` — `keyUp` + `systemDefined`. Enabled only while
  `gCycleShortcutActiveKeycode`/`gMissionControlActiveKeycode` is set or a
  bare-Fn candidate is live: the swallowed release and the media keys that
  cancel a bare-Fn tap. `keyUp` alone was half of the old tap's traffic.
- `gModifierKeyTap` — `flagsChanged`. Enabled only while a cycle shortcut is
  configured and the recorder is idle. With none recorded (the default) the
  callback passed every modifier transition straight back.

`syncKeyboardAuxiliaryTaps()` derives both states and runs from a `defer`
covering every exit of `eventTapCallback`, plus `persistCycleShortcut()` and
the recorder's start/stop. Because the callback re-runs it on the next
`keyDown`, a missed call site self-corrects within one keystroke.

**Shortcut matching logic** in `eventTapCallback`:
- Extract `flags` and `keycode` from the event
- Check `flags.intersection(kRelevantModifiers) == gModMask` — ensures *exactly* the right modifiers (no extras)
- Match keycode against `gKeyLeft` (direction -1) or `gKeyRight` (direction +1)
- Bounds check via `getSpaceList()` — don't switch past the first/last space

The optional cycle shortcut is user-recordable in the Features pane. Ordinary
shortcuts match exact keycode + Control/Option/Shift/Command modifiers on `keyDown`;
their repeat and paired `keyUp` events are swallowed so the frontmost app sees
nothing. Bare Fn is the one supported modifier-only binding: it is recognized on
release, and any ordinary, media/system-defined, or modifier key event while Fn is
held cancels the cycle. Repeated Fn-down events preserve that cancelled state, and
modifiers already held when Fn goes down cancel it immediately. The shortcut moves
to the next space on the cursor's display and wraps from the last space to the first.
It is independent of the Instant Space switch toggle, but stands down at the Normal
transition-speed tick like all synthetic switching, and in Mission Control, while a
window is being dragged, or when the space layout is unknown — `cycleToNextSpace()`
owns all three checks and returns whether it acted. An ordinary binding that stands
down is passed through to macOS (and so is its `keyUp`, since no active keycode was
recorded); a bare-Fn binding stays swallowed either way, as the key has no native
behavior worth restoring mid-press. At Normal, the Features pane
dims the recorder and toggle and shows a System Settings-style warning subtitle;
the saved enabled state and shortcut remain unchanged and return at faster speeds.

### Feature 2: Auto-follow on Cmd+Tab (`SwoopObserver` in `AutoFollow.swift`)

Listens for `NSWorkspace.didActivateApplicationNotification`. When an app is activated:

1. **Suppression checks** — two, deliberately narrow (issue #24: a blanket
   time window made rapid Cmd+Tab fall back to the animated switch):
   - *Echo guard* — skip if this is the **same PID** we followed within
     `kAutoFollowEchoWindow` (300ms). Reset the moment any other app
     activates, so alternating between two apps is never suppressed.
   - *User-navigation guard* — skip if within `kAutoFollowSuppressionWindow`
     (300ms) of `gLastSpaceSwitchTime`, which auto-follow's own switches
     deliberately do not stamp (see below)
2. `findSpaceForPid(_:)` uses `visibleWindowSpaces(for:)` to find the app's window spaces, returns 0 if already reachable (falls back to space-anchored helper windows for windowless apps — see "Window filtering criteria")
3. `switchToSpace(_:)` computes direction + steps and posts that many gestures

The app is intentionally **never activated by us** (`app.activate()` is not called): the system activation already in progress brings the app to focus, and sending a `kAEActivate` Apple Event makes some apps (e.g. Safari) exit background modes like Picture-in-Picture.

### Feature 3: Instant trackpad swipe (`swipeTapCallback` in `SwipeIntercept.swift`)

**Off by default** (`Defaults.trackpadSwipe`, stored under the legacy key
`spacerabbit.threeFingerSwipe` so existing opt-ins survive the rename) — it swallows the user's
physical gesture, a bigger behavioral change than the additive features above.
Ported from [joshuarli/iss](https://github.com/joshuarli/iss) (same repo the macOS 27
augmentation came from).

A second CGEvent tap listens for the private gesture (29) + DockControl (30) event
types and intercepts the *real* horizontal 3-finger (or 4-finger) trackpad swipe:

1. **Began** → start tracking, swallow (the native animated switch never starts)
2. **Changed** → first non-zero `kCGEventGestureSwipeProgress` reveals the direction;
   fire `postSwitchGesture` (bounds-checked via `getSpaceList()`, stands down when
   the layout is unknown), keep swallowing — and keep reading progress for a
   **reversal** (see below)
3. **Ended** → fallback: if nothing fired yet (very quick flick), use the final
   `kCGEventGestureSwipeVelocityX` sign. On macOS 27+ the Ended event is passed through
   with progress/velocity zeroed (the Dock needs to see the gesture close); pre-27 it
   is swallowed. **Cancelled** (phase 8) → reset without firing
4. Companion gesture (29) envelopes are swallowed while a swipe is tracked

**Mid-gesture reversal.** macOS lets an in-progress swipe be taken back without
lifting the fingers — peek at the next space, reverse the motion, land back where
you started. Committing a single instant jump and ignoring the rest of the
swallowed gesture removed that; the interceptor now keeps reading progress for as
long as the fingers are down and posts the **inverse** transition when they
travel back `kGestureReversalThreshold` (0.2) from the furthest point reached
since the last thing it acted on. Both axes share that logic
(`requestedTravelSign` / `extendGestureExtreme` in `SwipeIntercept.swift`), so it
covers horizontal Space swipes, the Mission Control overview's carousel, and
vertical Mission Control / App Exposé entry and dismissal. A gesture can reverse
any number of times.

Three properties worth keeping:
- **Measured from the extreme, not from touchdown**, so a short peek and a long
  swipe reverse on the same amount of finger travel.
- **Well above `kGestureDirectionThreshold`** (0.05). Fingers drift back as they
  settle or lift, and unlike a native animation that has not committed yet, every
  crossing here is a real visible transition — so the reversal threshold is a
  deliberate motion, not a wobble.
- **The intent is latched even when the switch is declined** (an edge, or an
  unreadable layout), so a refused switch is not retried on every one of the
  remaining samples — but the reversal is still measured from there, which is what
  makes reversing *out of* an edge work.

For the vertical axis the reversal needs no state lookup: each posted direction
toggles between the desktop and one overview, so the inverse always undoes it.
`pendingMissionControlDirection` is therefore the *opening* decision only.

**Direction sign of real trackpad events** (independent of the posting-side
convention): right-space iff sign `> 0` on macOS ≤ 26, but `< 0` on macOS 27+, whose
augmented path inverted the reported sign (checked first, via
`requiresEventAugmentation()`). Pre-Tahoe (macOS 15 and earlier) was long assumed to
match 27+ — mirroring iss's build-time `ISS_SWIPE_DIRECTION_REVERSED` — but users on
those releases reported every swipe going the wrong way, so the rule is now the same
for everything below 27.
**"Natural scrolling" needs no handling** and reading
`com.apple.swipescrolldirection` is a trap (PR #22, reverted): the window server
already flips the reported sign when the setting is off, so the table above holds in
both modes and any correction on top of it double-flips the result. Measured on macOS
26 with natural scrolling OFF: a left-to-right swipe reports progress `+0.045` and must
move right — the same rule as ON. A direction complaint is far more likely to be the
synthetic-echo bug below than a scrolling-preference bug.

**Synthetic-event marker (`kSyntheticGestureMarker`)** — Space Rabbit's own synthetic
gestures post into the same session tap and would loop right back into this tap.
Every posting path in `SpaceSwitching.swift` calls `markSyntheticGesture(_:)` on each
event before posting, stamping `.eventSourceUserData`; the swipe tap checks that field
first and waves those events straight through. `CGEventCreateFromData` does not
preserve that field, so augmented events must be stamped **after**
`augmentDockSwipeEvent` flattens and rebuilds them.

Do **not** go back to counting pending synthetic events (`gSwipePassthroughCount`, the
joshuarli/iss technique, removed): the real gesture's own Changed samples carry the
same event subtypes the counter keyed on, so they drained the budget before our
synthetic events arrived. The leftover synthetic Ended was then read as a real swipe
and fired a second switch from its `±kInstantSwitchVelocity` sign — a cascade that
looks exactly like a direction bug.

**Tap lifecycle** — unlike the keyboard tap (installed once at startup), these taps are
created/torn down on demand by `updateSwipeTap()` so they only exist while `gEnabled`
and either opt-in gesture feature is enabled. Called from startup,
`SwoopMenu.setEnabled`, both gesture toggles (menu + settings), and the speed
slider. The "Normal" speed tick gates both horizontal Space swipes and Mission
Control transitions.

**Two taps, split by event type.** A `.defaultTap` is a synchronous IPC round-trip —
macOS cannot deliver the event until this process has woken, run the callback and
replied — so what the taps subscribe to is a direct CPU cost. The generic gesture
envelopes (29) fire continuously for *any* finger on the trackpad, including plain
cursor movement (measured on macOS 26: ~20–60/s while moving, versus a handful of
DockControl events), and a bare do-nothing tap on them costs ~0.5% CPU on its own.
They are only ever acted on while a gesture is already claimed, so they get their own
tap (`gGestureEnvelopeTap`), created alongside the main one but kept **disabled**
until Began and re-disabled the moment tracking ends. `syncGestureEnvelopeTap()`
derives that from the tracking flags and runs from a `defer` covering every exit of
`swipeTapCallback`, so no branch can strand it enabled.

This is behavior-preserving, not a trade-off: the envelope paired with a DockControl
event arrives just *before* it (same millisecond, measured), so the Began's own
companion envelope is already past by the time the tap could be enabled — but the
interceptor never swallowed that one either, since nothing is tracked yet when it
arrives. Every envelope the code does swallow belongs to a later phase, a full sample
period (~8 ms) away. Do **not** merge the two masks back into one tap.

**Global speed contract** — `gSwitchSpeed` is the sole speed preference for
keyboard Space shortcuts, Cmd+Tab auto-follow, physical Space swipes, and Mission
Control entry/dismissal. Every synthetic transition resolves through
`currentSwitchVelocity()`. Horizontal switches use that value as terminal
velocity; Mission Control maps the same value to its timed progress duration.
At Normal, each path stands down and leaves the transition native. The only
safety exception is a cross-display target at a non-Instant tick: synthetic
DockSwipes carry no display identity, so that path declines and lets macOS
perform its native transition.

The persisted slider value is normalized at launch to the supported
`0.0...1.0` quarter-step ticks. Non-finite or corrupt values reset to Instant,
preventing invalid velocities or animation durations from reaching either
gesture path.

### Optional Instant Mission Control (`SwipeIntercept.swift`, `EventTap.swift`)

Off by default and independent from Instant Trackpad Swipe. Both vertical
overviews the trackpad reaches — Mission Control and **App Exposé** — plus
horizontal space navigation *inside* the Mission Control overview all follow the
shared transition-speed slider: Normal leaves the physical gesture native,
Fast/Faster/Fastest use progressively shorter timed progress streams, and
Instant removes the transition.

**Keyboard triggers.** The same toggle also owns the two keyboard ways into
Mission Control, handled by the *keyboard* tap in `EventTap.swift`, not the
gesture tap: the dedicated function-row Mission Control key
(`kMissionControlKeycode` = 160, a distinct keycode rather than F3 with a
modifier, so the top-row-mode setting is irrelevant) and the "Mission Control"
system hotkey (`gBindingMissionControl`, default Control+Up). Both are swallowed
and replaced with the same controlled vertical stream the gesture uses, so they
follow the shared slider too. The key press is a *toggle* and carries no
direction, so `triggerMissionControlTransition` reads it from what is on screen
— `.desktop` enters, `.missionControl` dismisses — and stands down otherwise
(see "Mission Control stand-down"). Standing down passes the key through, and
leaves no active keycode so its `keyUp` passes through too; a claimed press
swallows its `keyUp` as well, since the hardware key gives no way to tell which
of the two edges Dock acts on. Autorepeat while the key is held is swallowed
without re-firing. The key is independent of the Instant Space switch toggle.
Pressing it produces no DockSwipe of its own — Dock runs its animated
transition internally — which is why the key event itself has to be
intercepted.

Mission Control and App Exposé share one vertical DockSwipe axis
(`motion = 2`) — the same gesture reaches both, and only the direction and the
state it lands in tell them apart. Because physical Began does not reliably
carry direction, the tap copies and holds Began (plus companion events) once the
Dock state resolves to any of `.desktop` / `.missionControl` / `.appExpose`; the
direction is settled later, from Changed progress.

Real vertical trackpad input uses screen-coordinate signs on macOS 26:
finger-up is negative, finger-down positive. That physical-input convention is
inverted before posting, because the synthetic vertical DockSwipe reads `+1` as
up and `-1` as down. `pendingMissionControlDirection` owns the four combinations
that do something on screen — desktop→up enters Mission Control, desktop→down
enters App Exposé, and either overview is dismissed by the opposite direction —
and stands down on the two that do nothing natively (no "further up" from
Mission Control, no "further down" from App Exposé). The sign is the *gesture*,
not the destination: `+1` enters from the desktop but dismisses from App Exposé.
Show Desktop, cancellation, copy failure, unavailable private state, or
synthetic construction failure replays the held prefix through the tap proxy
before the current event continues natively.

**Direction is not read from the first non-zero progress sample**
(`kGestureDirectionThreshold`, issue #43). Progress reports absolute gesture
travel, so samples just after touchdown are near zero and signed by whichever
way the fingers happened to drift — a downward swipe that rocked up by a
thousandth resolved as Mission Control entry. Both axes therefore wait for
`|progress| >= 0.05` before committing, which a real swipe crosses within a few
milliseconds of travel. Do not lower this back toward zero to shave latency: the
physical gesture is already swallowed by then, so a misread sign is not
recoverable.

Both directions use the segmented vertical sequence from
[FasterSwiper](https://github.com/mgbowen/FasterSwiper). Fast/Faster/Fastest post
epsilon progress on Began, then fresh Changed events at 120 Hz along a cubic
ease-out curve before Ended. Their durations are 0.20/0.16/0.12 seconds,
calibrated to the shared slider's horizontal 50/60/70 velocity ticks. Sending
`Changed ±1.0` immediately and varying only Ended velocity does not animate
Mission Control because the Dock has already reached the boundary. Instant is
therefore a separate three-event path: epsilon Began, `Changed ±1.0`, then
Ended at `±1.0` with velocity `±9999`. Field 129 carries that terminal
velocity despite its private `VelocityX` name.

Every vertical event receives a fresh serialized field-4205 IOHID payload on
every supported macOS release. Began is injected through the active tap proxy;
timed Changed/Ended samples run on a serial user-interactive queue and use the
session tap, keeping the event-tap callback non-blocking. Before Began, the app
constructs a complete fallback Changed/Ended pair; any later allocation or
augmentation failure uses that pair rather than leaving an open Dock gesture. A
new animation invalidates an overlapping one and posts the old terminal pair
through the active tap proxy before its own Began, giving the two streams a
deterministic order. (Bare vertical events are rejected on macOS 26 even though
bare horizontal events still work there.) The vertical path does not use
horizontal gesture envelopes or horizontal sign rules. macOS 27+ additionally
receives the stricter mirrored fields. The remaining physical stream is
swallowed, except that macOS 27+ receives
a rebuilt Ended event with progress/X/Y velocity zeroed in both its ordinary fields
and its field-4205 payload, matching the horizontal interceptor's cleanup without
leaving contradictory serialized motion. If that rebuild fails, the ordinary fields
alone are zeroed and the Ended still goes through — dropping it would leave the
Dock's gesture state open, which is the worse failure.
The interceptor is limited to the known macOS 15–27 schemas; an unknown future
major release leaves the option inert and the physical gesture native.

**Horizontal swipes inside the overview.** Mission Control navigates spaces from
the same horizontal 3-finger swipe the desktop uses, so this toggle also owns
that gesture while the overview is up — independently of the Instant Trackpad
Swipe toggle, which owns the desktop ones. The desktop recipe cannot be reused
(issue #16): a fully-committed boundary jump is evaluated against the overview's
state, the screen blanks, and it lands back where it started. The horizontal
gesture therefore goes out through the *same* segmented Began → progress → Ended
machinery as the vertical transitions, on `motion = 1`
(`postOverviewSpaceSwitch` / `postControlledDockSwipe`). Only the sign rule
differs by axis: horizontal keeps the desktop path's posting convention, so
macOS 27+ inverts it (negative moves right) while everything below it does not,
whereas vertical is `+1`/`-1` on every release. Direction is resolved from
Changed progress under the same `kGestureDirectionThreshold` the desktop uses,
the gesture is bounds-checked against `getSpaceList()`, and only the
`mission-control` OS space qualifies — App Exposé, Show Desktop, and unreadable
private state stay native. The desktop branch keeps the cheap fail-open
layer-18 test it always had, so an unreadable window list cannot regress it.

**App Exposé does not accept this stream** (tried and reverted). Its overview
navigates spaces from the same physical horizontal swipe, so admitting
`show-front` to the branch above looks like free parity with the vertical path
— but the segmented carousel stream that moves Mission Control moves nothing
there. The outcome is the worst of both: the physical gesture is swallowed on
Began and no replacement lands, so horizontal swiping inside App Exposé stops
working altogether. Keep `show-front` out of this branch unless a recipe is
found that the overview actually acts on — and note the desktop's
fully-committed boundary jump is not a candidate, since that is exactly what
issue #16 ruled out for Mission Control. This concerns only the *horizontal*
gesture; vertical entry into and dismissal of App Exposé do work and ship.

**Space shortcuts inside the overview.** The system "Move left/right a space"
bindings navigate the same carousel, so Feature 1 hands them to
`postOverviewSpaceSwitch` too rather than standing down, gated on the identical
condition (`canDriveOverviewSpaceSwitch()` in `EventTap.swift`). Only these two
one-step bindings are converted. "Switch to Desktop N" and the cycle shortcut
are multi-step and still stand down — one segmented stream moves the carousel by
exactly one space, so those would need a chained sequence to be correct, and an
animated native jump is better than a wrong instant one.

### Feature interaction (suppression guard)

The two features suppress each other to prevent loops. After instant-switch fires, `gLastSpaceSwitchTime` is stamped. Auto-follow checks this timestamp and skips if within 300ms. The `activeSpaceDidChangeNotification` observer in `main.swift` also stamps this time for trackpad-initiated switches (which bypass the event tap entirely).

**Auto-follow's own switches are exempt from that stamp** (issue #24). The
space-change notification lands only once the transition settles — hundreds of
milliseconds later — so stamping it held auto-follow suppressed far past the
300ms window and handed the user's next quick Cmd+Tab back to macOS's animated
switch. That is why hammering Cmd+Tab animated while a gentle pace did not, and
why Ctrl+Arrow was unaffected (Feature 1 never consults the guard). Auto-follow
therefore records its destination in `gAutoFollowTargetSpace`; the observer
recognizes the matching change as its own, clears the record and skips the
stamp. The record expires after `kAutoFollowSelfChangeWindow` (1.5 s) so a
switch that never landed cannot swallow an unrelated stamp later, and a
multi-step follow's intermediate notifications (which don't match the
destination) still stamp normally.

### Mission Control stand-down (`isMissionControlActive()` in `SpaceSwitching.swift`)

The existing Space-switch features stand down while a Mission Control-style
overview (Mission Control, App Exposé, Show Desktop) is on screen, letting macOS
handle the input natively. The overview drives space navigation itself, and a
synthetic DockSwipe posted into it is evaluated against the overview's state
rather than the desktop's: the screen blanks, swipes, and lands back on the
space the user started from (issue #16).

Detection is a synchronous `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` scan
for a **Dock-owned window at `kCGWindowLayer` 18** — the display-sized overlay the
Dock keeps up for the whole duration of the overview, and the same marker yabai
uses (`src/mission_control.c`). `kCGWindowName` is deliberately *not* part of the
test (yabai additionally requires it to be nil): it needs Screen Recording
permission, which Space Rabbit never asks for, so it reads as `nil` for every
window regardless of state.

Where the check runs matters — it copies the window list, so it is only reached
once an action is about to happen, never per event:

- **Feature 1** — after a shortcut has matched (the left/right bindings, the
  "Switch to Desktop N" loop, and the cycle shortcut inside
  `cycleToNextSpace()`), not for every `keyDown`. For a bare-Fn binding that
  means one lookup per Fn *release*, and only once the press has qualified as
  a bare tap. The left/right bindings do not stand down on a positive answer:
  the cheap layer-18 test picks the recipe (desktop jump versus overview
  carousel) and only then is the exact state resolved, so the common desktop
  case still costs one lookup — the same two-tier shape Feature 3 uses.
- **Feature 3** — on the Began phase only. The answer picks which recipe replaces
  the swipe (desktop jump versus overview carousel) or whether to stand down;
  standing down means *not tracking* the gesture, so all later phases pass
  through via the existing `gSwipeTracking` checks, one lookup per swipe instead
  of one per sample. Only when the layer-18 marker is present does the Began also
  resolve the exact overview state, so the desktop path still costs one lookup.
- **Instant Mission Control** — before holding vertical Began, and (for the
  keyboard triggers) only after the Mission Control key or hotkey has matched.
  An absent layer-18 marker identifies the desktop. When a marker exists,
  `SLSCopySpaces` and `SLSSpaceCopyName` must identify the OS space as either
  `mission-control` or `show-front` (App Exposé) — the vertical gesture drives
  both; Show Desktop, conflicts, and failed private-state reads remain native.
  The keyboard path needs the same answer for a second reason: the press is a
  toggle, so the state *is* its direction — and it keeps standing down on App
  Exposé, where the Mission Control key crosses to Mission Control rather than
  dismissing, which no vertical transition reproduces.
- **Feature 2** — after the speed and suppression-window guards, before the
  window-to-space lookups.

## Private APIs in use (`PrivateAPI.swift`)

### CGS functions (resolved via `loadSymbol()` / `dlsym` at startup)

| C symbol | Swift variable | Signature | Purpose |
|---|---|---|---|
| `CGSMainConnectionID` | `cgsMainConnection` | `() -> Int32` | Current session's connection ID |
| `CGSGetActiveSpace` | `cgsGetActiveSpace` | `(cid) -> UInt64` | Active space ID on main display |
| `CGSCopyManagedDisplaySpaces` | `cgsCopyDisplaySpaces` | `(cid, displayUUID?) -> CFArray?` | All displays + their spaces |
| `SLSCopySpacesForWindows` | `slsCopySpacesForWindows` | `(cid, spaceType, windowIDs) -> CFArray?` | Maps window IDs → space IDs |
| `SLSCopySpaces` | `slsCopySpaces` | `(cid, mask) -> CFArray?` | Current OS-managed spaces used to identify overview state |
| `SLSSpaceCopyName` | `slsSpaceCopyName` | `(cid, spaceID) -> CFString?` | Internal OS-space names such as `mission-control` and `show-front` |

**Do not use `CGSManagedDisplaySetCurrentSpace`:** it was tried for instant cross-display switching and reverted. It flips the window server's current-space pointer without running the real transition, desyncing state — target-space windows composite on top of the still-displayed space (worst with fullscreen spaces), and subsequent edge bounds-checks read the stale pointer and overshoot into a black non-existent space.

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

**`"Display Identifier"` caveat:** not always a UUID — some systems (notably single-display setups) report the literal string `"Main"` (issue #6). `getSpaceList()` translates `"Main"` to the primary display's UUID before comparing against the cursor's display, and falls back to active-space matching when no identifier matches at all. Never compare this field to a cursor/display UUID directly.

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

### macOS 27+ gesture augmentation

macOS 27's Dock **rejects** the bare gesture pairs above (the user hears the error sound). `postSwitchGesture` routes to an augmented path, gated by `requiresEventAugmentation()` (`ProcessInfo` major version ≥ 27). Technique reverse-engineered in [joshuarli/iss](https://github.com/joshuarli/iss) commit `09beeb6`. Three differences from the legacy path:

1. **Extra dock-event fields**: field 134 (`kCGEventGesturePhase2`) mirrors the phase, 138 (`kCGEventGestureFlavor`) = 3.0 (`kIOHIDGestureFlavorDockPrimary`), 169 (`kCGEventGestureTimestamp`) = `mach_absolute_time()` as a double, 125 (`kCGEventGesturePositionX`) = 0.1 (must be non-zero or the Dock discards the event). Progress (124) = ±1.0 on **every** phase; Ended-phase velocity = ±9999 (`kAugmentedInstantVelocity`). Fields 135/119/139 from the legacy recipe are not set.
2. **Inverted sign convention**: NEGATIVE progress/velocity moves right, positive moves left (opposite of the legacy path). Do **not** "un-invert" these to match the legacy path — that was tried (PR #15) and reverted, and it is the cause of issue #19: every switch travels the wrong way, so Ctrl+Arrow walks to the first/last space instead of stepping, and at either edge the Dock flashes black and rubber-bands back to the starting space. Measured on build 26A5388g by posting the augmented sequence and reading the index back from `CGSCopyManagedDisplaySpaces`: `+1.0/+9999` moves left, `-1.0/-9999` moves right. This is the *posting* convention only — reading a real trackpad gesture's direction has its own separate rule (`isRightSwipe`, see Feature 3).
3. **Serialized IOHID payload under field 4205**: the Dock validates the event against a packed little-endian IOHID queue payload — `IOHIDSystemQueueElementHeader` (28 B) + `IOHIDFluidTouchGestureData` (40 B) + `IOHIDVelocityEventData` (28 B, appended only when velocity ≠ 0 or phase = Ended) — mirroring the event's gesture fields (positions/progress/velocity as signed 16.16 fixed-point, phase in the high byte of the gesture's `options`). Field 4205 can NOT be set via the normal field-setter API: the event is flattened with `CGEventCreateData`, any existing field-4205 record is replaced with a current packed payload, and the event is rebuilt with `CGEventCreateFromData`. The serialized header must be `00 00 00 02` — anything else means Apple changed the format and `augmentDockSwipeEvent` bails (gesture not posted). Replacing the record means walking every record in the blob, and an unrecognized record shape would otherwise disable the whole path; for the freshly-built events (which carry no payload of their own) it therefore falls back to plain appending, the behavior that shipped before the walker existed. Only the macOS 27 vertical-cleanup event — a *copy of a physical gesture*, which may already hold a payload — passes `mayCarryExistingPayload: true` and stays strict, since a second contradictory payload would be worse than none. Swift structs make no layout guarantees, so the payload is serialized field-by-field (`Data.appendLE`), not by casting structs — the layout was verified byte-identical against the packed C structs.

The augmented sequence is **Began + Changed + Ended** (three pairs, not two — macOS 27 requires the Changed phase). All three events are built and augmented up front so a mid-sequence failure posts nothing (a Began without its Ended would leave the Dock's gesture state half-open). Animated slider velocities (50–70) pass through unclamped — **uncalibrated on macOS 27**; only the instant velocity (9999) is confirmed working upstream. Anything ≥ `kInstantSwitchVelocity` (400) is mapped to 9999.

### Symbolic hotkeys (`Shortcuts.swift`)

Read from `CFPreferencesCopyAppValue("AppleSymbolicHotKeys", "com.apple.symbolichotkeys")`.

| Hotkey ID | Meaning | Constant |
|---|---|---|
| `"32"` | Mission Control | `kHotkeyMissionControl` |
| `"79"` | Move left a space | `kHotkeyMoveLeftSpace` |
| `"81"` | Move right a space | `kHotkeyMoveRightSpace` |

Entry structure: `{ enabled: Bool/Int, value: { parameters: [unused, keycode, carbonMods], type: "standard" } }`. Keycode 65535 = empty slot. Carbon modifier bits decoded via `CarbonModifier` enum (shift=0x020000, control=0x040000, option=0x080000, command=0x100000).

## Window filtering criteria

Used in `visibleWindowSpaces(for:)` — the window-lookup helper behind `findSpaceForPid`:

1. `kCGWindowOwnerPID` must match the target PID
2. `kCGWindowIsOnscreen` must be 1 (excludes minimized/hidden windows)
3. `SLSCopySpacesForWindows(cid, 7, [windowID])` must return a non-zero space ID
   - The magic `7` = `kSLSSpaceTypeAll` (all space types: user, fullscreen, etc.)

`visibleWindowSpaces` does a single window-list pass (kept fast — it sits on the latency-critical auto-follow path) and splits results by `kCGWindowLayer`: layer 0 → `normal` (regular app windows), any other layer → `anchored` (space-anchored helper windows).

**"All Desktops" windows (issue #10):** a window `SLSCopySpacesForWindows` resolves to **more than one** space is assigned to every space — the Dock's "Options > Assign To: All Desktops" (sticky) setting, which reports every user desktop of the window's display, or a status/desktop window tagged onto all spaces (verified empirically on macOS 26; same multi-space heuristic yabai uses for stickiness). Such a window is reachable wherever the user is, and its space list is MRU-ordered — chasing `first` would yank the user back to the space the app was last hidden/minimized on. It therefore contributes no chase target and instead sets the group's `hasAllSpacesWindow` flag, which `findSpaceForPid` treats like an onscreen window (returns 0, no switch).

**Helper-window fallback in `findSpaceForPid`:** when an app has zero normal windows, macOS's activation logic still navigates (with the slide animation) to any space-anchored window the app owns — Finder's desktop-icons window, or status-item windows of menu-bar apps (e.g. Things), typically anchored to the first space. `findSpaceForPid` falls back to the `anchored` group and returns its frontmost space, so auto-follow preempts the native animated switch with an instant one to the same destination. This preemption races the Dock's own animated switch — see `kAutoFollowSuppressionWindow` notes.

## Global state (`State.swift`)

All runtime state is module-level globals (not a singleton class). Main-thread
ownership remains the default. The only concurrency exception is the Mission
Control animator state, which is confined to its dedicated serial queue and is
documented at its declaration in `State.swift`.

| Variable | Type | Purpose |
|---|---|---|
| `gTap` | `CFMachPort?` | The active CGEvent tap (keyboard, Feature 1) — `keyDown` only |
| `gClaimedKeyTap` / `gClaimedKeyTapSource` / `gClaimedKeyTapEnabled` | `CFMachPort?` / `CFRunLoopSource?` / `Bool` | `keyUp` + `systemDefined` companion — enabled only while a press is claimed or a bare-Fn candidate is live (`syncKeyboardAuxiliaryTaps()`) |
| `gModifierKeyTap` / `gModifierKeyTapSource` / `gModifierKeyTapEnabled` | `CFMachPort?` / `CFRunLoopSource?` / `Bool` | `flagsChanged` companion — enabled only while a cycle shortcut is configured and the recorder is idle |
| `gSwipeTap` / `gSwipeTapSource` | `CFMachPort?` / `CFRunLoopSource?` | Shared gesture-intercept tap, DockControl (30) only — exists while at least one gesture feature is active (`updateSwipeTap()`) |
| `gGestureEnvelopeTap` / `gGestureEnvelopeTapSource` / `gGestureEnvelopeTapEnabled` | `CFMachPort?` / `CFRunLoopSource?` / `Bool` | Companion tap for the high-rate gesture envelopes (29) — created with `gSwipeTap` but enabled only while a gesture is claimed (`syncGestureEnvelopeTap()`) |
| `gEnabled` | `Bool` | Master on/off toggle |
| `gInstantSwitchEnabled` | `Bool` | Feature 1 toggle |
| `gAutoFollowEnabled` | `Bool` | Feature 2 toggle |
| `gCycleShortcutEnabled` | `Bool` | Whether the configurable cycle shortcut is active |
| `gCycleShortcut` | `CycleShortcut?` | Recorded cycle keycode, exact modifiers, and display label (`nil` when cleared) |
| `gIsRecordingCycleShortcut` | `Bool` | Makes the global event tap stand down while Preferences records a replacement |
| `gTrackpadSwipeEnabled` | `Bool` | Feature 3 toggle (default **false** — opt-in) |
| `gInstantMissionControlEnabled` | `Bool` | Mission Control entry/dismissal transition toggle (default **false** — opt-in) |
| `gSwipeTracking` / `gSwipeInOverview` | `Bool` | Per-horizontal-gesture state of the swipe intercept — claimed, and whether Began happened inside the Mission Control overview (reset via `resetSwipeIntercept()`) |
| `gSwipeIntentDirection` / `gSwipeIntentProgress` | `Int` / `Double` | Direction the current horizontal gesture last acted on (`0` = none, so it doubles as "already fired") and the furthest progress reached since — the reversal reference |
| `gMissionControlSwipeTracking` / `gPendingMissionControlEvents` / `gPendingMissionControlOverviewState` | `Bool` / `[CGEvent]` / `DockOverviewState?` | Claimed vertical stream, copied prefix, and its exact desktop/Mission Control origin awaiting direction/native replay |
| `gMissionControlIntentSign` / `gMissionControlIntentProgress` | `Int` / `Double` | Same reversal pair for the claimed vertical gesture, on the *physical* sign convention |
| `gMissionControlAnimation` / `gMissionControlAnimationID` | `MissionControlAnimationState?` / `UInt64` | Active timed vertical transition and generation ID; accessed only on the Mission Control animation queue |
| `gSwitchSpeed` | `Double` | Transition speed slider tick (0.0–1.0 in 0.25 steps; 0.0 = native macOS animation, 1.0 = instant) |
| `gLastSpaceSwitchTime` | `Date` | For auto-follow suppression (initialized to `.distantPast`). Stamped by Features 1/3 and by non-auto-follow space changes |
| `gLastFollowedPid` / `gLastFollowedTime` | `pid_t` / `Date` | Last app auto-follow chased — the echo guard's scope (`-1` = none) |
| `gAutoFollowTargetSpace` | `CGSSpaceID` | Destination of the outstanding auto-follow switch, so its own space-change notification is not mistaken for user navigation (`0` = none) |
| `gSwitchCount` | `Int` | Lifetime switch counter (persisted periodically) |
| `gSwitchCountSaved` | `Int` | Last persisted value (avoids redundant writes) |
| `gKeyLeft` / `gKeyRight` | `Int64` | Keycodes (default: 123/124 = arrow keys) |
| `gModMask` | `CGEventFlags` | Modifier mask (default: `.maskControl`) |
| `gMenu` | `SwoopMenu?` | The menu bar status item instance |

### UserDefaults keys (`Defaults` enum)

`spacerabbit.enabled`, `spacerabbit.instantSwitch`, `spacerabbit.autoFollow`,
`spacerabbit.cycleShortcut.enabled`, `.keycode`, `.modifiers`, `.label`,
`spacerabbit.threeFingerSwipe` (the "Instant Trackpad Swipe" toggle — legacy spelling kept deliberately, see `Defaults.trackpadSwipe`), `spacerabbit.instantMissionControl`, `spacerabbit.switchSpeed`, `spacerabbit.switchCount`, `spacerabbit.showMenuBarIcon`,
`spacerabbit.lastUpdateCheck`, `spacerabbit.pendingUpdateVersion`,
`spacerabbit.pendingUpdateURL` (the last three belong to the update throttle — see
"Update flow"; none has a `g` global, they are read and written where they are used).

The four cycle-shortcut keys are read and written as a unit by
`loadCycleShortcut()` / `persistCycleShortcut()` in `State.swift` (the loader is
called from `SwoopMenu.init` with the rest of the startup state). A keycode of
`-1` is the sentinel for a recorder the user explicitly cleared, which the loader
turns back into `gCycleShortcut = nil` with the feature forced off — distinct from
a fresh install, whose registered default is a latent (disabled) bare Fn.

Menu bar icon visibility has no `g` global: the live truth is `statusItem.isVisible` (`SwoopMenu.isMenuBarIconVisible`), persisted through `setMenuBarIconVisible(_:)`.

Persistence strategy: `flushSwitchCount()` writes to disk only if `gSwitchCount != gSwitchCountSaved`. Called every 300s by timer and once on app termination. Acceptable to lose a few counts on crash.

## Key named constants

| Constant | File | Value | Purpose |
|---|---|---|---|
| `kSLSSpaceTypeAll` | SpaceSwitching | `7` (Int32) | Bitmask for "all space types" in SLS calls |
| `kInstantSwitchProgress` | SpaceSwitching | `2.0` | Fully-committed swipe progress |
| `kInstantSwitchVelocity` | SpaceSwitching | `400.0` | Velocity above Dock's instant threshold |
| `kMissionControlEpsilon` | SpaceSwitching | `1/65536` | Smallest signed 16.16 value used for vertical entry Began/Ended |
| `kAugmentedInstantVelocity` | SpaceSwitching | `9999.0` | Hardened instant velocity for macOS 27+ horizontal gestures and Instant Mission Control transitions (horizontal sign inverted: negative = right) |
| `kAnimatedVelocityMin/Max` | SpaceSwitching | `40.0` / `80.0` | Animated velocity band for the transition-speed slider (from InstantSpaceSwitcher's presets). `currentSwitchVelocity()` interpolates the Fast/Faster/Fastest ticks to 50/60/70, or returns `kInstantSwitchVelocity` at the "Instant" end cap. At the "Normal" tick `isNativeSwitchSpeed()` is true and **no gestures are posted at all** — the event tap passes shortcuts through and auto-follow stands down, giving macOS's native animation |
| `kMissionControlAnimationDurationSlow/Fast` | SpaceSwitching | `0.24` / `0.08` seconds | Duration endpoints that map the shared velocity band to Mission Control's timed progress stream. Slider ticks Fast/Faster/Fastest resolve to 0.20/0.16/0.12 seconds |
| `kAutoFollowSuppressionWindow` | AutoFollow | `0.3` (TimeInterval) | Grace period after a *user-driven* space switch before auto-follow kicks in |
| `kAutoFollowEchoWindow` | AutoFollow | `0.3` (TimeInterval) | Window in which a repeat activation of the **same** app reads as the echo of our own follow |
| `kAutoFollowSelfChangeWindow` | AutoFollow | `1.5` (TimeInterval) | How long `gAutoFollowTargetSpace` stays credible as the cause of a space-change notification |
| `kMissionControlWindowLayer` | SpaceSwitching | `18` (Int32) | `kCGWindowLayer` of the Dock's overview overlay — the Mission Control marker |
| `kCurrentOSSpacesMask` | SpaceSwitching | `(1 << 0) \| (1 << 3)` | Private mask used to query the active Dock-managed overview space |
| `kGestureMotionHorizontal` / `kGestureMotionVertical` | SwipeIntercept | `1` / `2` (Int64) | `kCGEventGestureSwipeMotion` values for Space and Mission Control swipes |
| `kGestureDirectionThreshold` | SwipeIntercept | `0.05` | Smallest `kCGEventGestureSwipeProgress` magnitude whose sign is trusted as the user's intended direction, on both axes. Below it the sample is touchdown wobble (issue #43) |
| `kGestureReversalThreshold` | SwipeIntercept | `0.2` | Travel back from a still-open gesture's furthest point that undoes what it already committed, on both axes — see "Mid-gesture reversal" |
| `kSyntheticGestureMarker` | SwipeIntercept | `0x53504152` ('SPAR') | Stamped into `.eventSourceUserData` on every gesture Space Rabbit posts, so the swipe tap passes its own events through |
| `kCGSGesturePhaseCancelled` | PrivateAPI | `8` (Int64) | Gesture phase seen only by the swipe-intercept tap |
| `kCGEventTypeSystemDefined` | PrivateAPI | `14` (CGEventType) | `NX_SYSDEFINED`, which CoreGraphics exposes no named case for. In the keyboard tap's mask so media keys cancel a bare-Fn candidate |
| `kCursorWarpRestoreDelay` | SpaceSwitching | `0.15` (TimeInterval) | How long the cursor stays parked on the target display after a cross-display warp switch (the Dock samples the cursor asynchronously) |
| `kRelevantModifiers` | EventTap | Control/Cmd/Alt/Shift | Modifier keys checked when matching shortcuts |
| `kFnKeycode` | State | `63` | Virtual keycode used for the recordable bare-Fn/Globe binding |
| `kMissionControlKeycode` | EventTap | `160` | Virtual keycode of the dedicated Mission Control key in the function row |
| `kCycleShortcutModifiers` | State | Control/Cmd/Alt/Shift/Fn | Exact modifier set checked for recorded cycle shortcuts. The automatic function flag on special/F-keys is normalized; a physically held Fn is still rejected as an unrecorded extra except for F-key bindings, where it is allowed to support either macOS top-row mode. |
| `kUpdateCheckInterval` | UpdateCheck | `3600` (TimeInterval) | Minimum gap between two *automatic* update checks; a launch inside the window reads the remembered release instead of the network |
| `kUpdateCheckLaunchDelay` | UpdateCheck | `5` (TimeInterval) | Settle time before the automatic check hits the network — skipped entirely on the cached path |
| `kMenuIconSize` | MenuBar | `16` (CGFloat) | Tinted SF Symbol size in menu items |
| `kDisabledIconAlpha` | MenuBar | `0.25` (CGFloat) | Menu bar icon opacity when disabled |
| `kEnableRowHeight` / `kEnableRowInset` | MenuBar | `36` / `14` (CGFloat) | Sizing for the header row hosting the master enable switch |
| `Layout.*` | Settings | various | All spacing/sizing/padding for preferences window |
| `CarbonModifier.*` | Shortcuts | hex bitmasks | Legacy Carbon modifier flag values |
| `kHotkeyMoveLeftSpace` | Shortcuts | `"79"` | System hotkey ID for left-space |
| `kHotkeyMoveRightSpace` | Shortcuts | `"81"` | System hotkey ID for right-space |
| `kHotkeyMissionControl` | Shortcuts | `"32"` | System hotkey ID for Mission Control |

## Update flow (`UpdateCheck.swift` + `UpdateInstall.swift`)

### Version checking

Two entry points in `UpdateCheck.swift`:
- **Automatic** (`checkForUpdatesAutomatically()`): called at launch, silently shows the menu bar banner if a newer release exists. **Throttled to one network check per hour** (`kUpdateCheckInterval`, stamped into `Defaults.lastUpdateCheck` by *both* entry points) — the app is quit and relaunched freely, and that must not turn into a burst of API requests.
- **Manual** (`checkForUpdatesManually()`): triggered from the "Check Now…" button in the settings window's Updates pane, reports results via callbacks so the caller can show dialogs. Never throttled, and it also passes `.reloadIgnoringLocalCacheData` — the GitHub API sends `Cache-Control: max-age=60`, so `URLSession`'s default policy would otherwise answer a user-requested check from the URL cache. The automatic path keeps the default policy, where the hour throttle makes the URL cache unreachable anyway.

Both hit `GET /repos/Tahul/space-rabbit/releases/latest` on the GitHub API, extract the `tag_name` and the first `.dmg` asset URL, and compare against `CFBundleShortVersionString`.

**Throttled launches still show the banner.** Every fetch caches its outcome:
a newer release is remembered in `Defaults.pendingUpdateVersion` +
`pendingUpdateURL`, and an up-to-date answer clears both. A launch that skips
the network restores the banner from that record, so an update stays visible
across relaunches instead of disappearing until the hour is up.
`pendingUpdateDownloadURL()` re-compares the stored tag against the running
version and self-clears when it is no longer newer — otherwise the record left
behind by an update the user has since installed would raise a banner for a
version already in place.

The `kUpdateCheckLaunchDelay` (5 s) courtesy delay lives *inside*
`checkForUpdatesAutomatically()` and wraps only the network path. The cached
path just reads UserDefaults, so it runs synchronously — delaying it would make
the banner appear late for no benefit. `main.swift` therefore calls
`checkForUpdatesAutomatically()` directly rather than wrapping it in its own
`asyncAfter`.

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
- Clicking "Install Now" in the dialog shown by the Updates pane's manual check

Both call `startUpdate(downloadURL:)` which delegates to `UpdaterWindowController.shared.start(downloadURL:)`.

## Data flow: toggle state changes

Toggles can be changed from two places. The sync pattern:

1. **Menu bar** → `SwoopMenu.toggleInstantSwitch`/`toggleAutoFollow`/`toggleTrackpadSwipe`/`toggleInstantMissionControl`: writes `gXxxEnabled` → `UserDefaults` → updates menu checkmark
2. **Settings window** → the matching `FeaturesPaneController` actions: writes `gXxxEnabled` → `UserDefaults` → calls `gMenu?.syncMenuItems()` to sync menu checkmarks
3. **Settings pane appears** (`viewWillAppear`, fires on every pane swap): refreshes its switch controls from globals

The cycle-shortcut row additionally uses `ShortcutRecorderButton` from
`ShortcutRecorder.swift`: clicking it installs
a temporary local key monitor and sets `gIsRecordingCycleShortcut` so the global tap
passes candidates through. Escape cancels, unmodified Delete clears, bare typing keys
require Control/Option/Command, standalone F-keys are allowed, and bare Fn is recorded
on release. Fn used with an ordinary, modifier, or media key does not record bare Fn;
Fn-produced F-keys are normalized to the same binding as standalone F-keys. Recording
a shortcut enables it; clearing disables it.

Both gesture toggles additionally call `updateSwipeTap()` from both places (the
shared tap only exists while at least one is active).

Master enable/disable (`gEnabled`) is only togglable from the menu bar (header-row switch or right-click on the icon; both go through `setEnabled`, which keeps the switch state in sync and calls `updateSwipeTap()`).

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
       ├─ Header row (custom-view item): bold "Space Rabbit" label + small
       │    native NSSwitch bound to gEnabled (Klack-style master toggle).
       │    Hosted in MenuKeyAppearanceView, whose viewDidMoveToWindow calls
       │    window?.becomeKey() on the menu's backing window — flips AppKit's
       │    key-appearance flag so the switch renders with the accent color
       │    while the app is inactive, WITHOUT stealing focus (never call
       │    NSApp.activate when opening the menu — it deactivates the
       │    frontmost app). Same technique Klack uses.
       ├─ Update-available banner (hidden by default, shown by checkForUpdatesAutomatically)
       ├─ Launch-at-login warning banner (hidden when SMAppService.mainApp.status == .enabled)
       ├─ "Configure:" section header
       ├─ Instant space switch toggle (checkmark, shortcut: S)
       ├─ Auto-follow on ⌘⇥ toggle (checkmark, shortcut: F)
       ├─ Instant trackpad swipe toggle (checkmark, shortcut: T,
       │    icon: rectangle.and.hand.point.up.left.filled)
       ├─ Instant Mission Control toggle (checkmark, shortcut: M,
       │    icon: rectangle.3.group)
       │    (the cycle shortcut is deliberately NOT here — secondary feature,
       │    settings-only)
       ├─ "Statistics:" section header
       ├─ Switch count + time-saved display (non-interactive)
       ├─ Version label
       ├─ Preferences… (shortcut: ,) → SettingsWindowController.shared.show()
       └─ Quit Space Rabbit (shortcut: Q)

SettingsWindowController (singleton, NSWindowDelegate)
  └─ SettingsRootViewController (NSSplitViewController — native sidebar layout)
       ├─ SettingsSidebarController — NSSplitViewItem(sidebarWithViewController:),
       │    fixed-width sidebar of TWO coordinated source-list NSTableViews: the
       │    main panes top-anchored, Updates + About pinned to the bottom edge
       │    (selection is exclusive across both lists). Plain template SF Symbol
       │    glyphs; native rounded accent selection. Full-size content view,
       │    hidden/transparent title bar; panes swapped lazily and cached;
       │    window resizes per pane
       ├─ AutoStartPaneController — Launch warning banner (orange, hidden when OK)
       │    + Launch at Login (SMAppService)
       ├─ FeaturesPaneController — three groups: Instant switch + Auto-follow +
       │    Instant trackpad swipe + Instant Mission Control toggles, then a
       │    group of its own for the optional "Cycle spaces shortcut" recorder
       │    + enable switch, then Transition speed slider (5 ticks, snapping:
       │    Normal = native macOS animation / Fast / Faster / Fastest / right
       │    end cap = "Instant", the default)
       ├─ AdvancedPaneController — Instant Dock hide (writes com.apple.dock
       │    autohide-time-modifier, killall Dock) + Show menu bar icon toggle
       │    (statusItem.isVisible; when hidden, relaunching the app reopens
       │    Preferences — see the AppDelegate notes in "Startup sequence")
       ├─ UpdatesPaneController — "Check Now…" button (mirrors the menu's manual
       │    check: sheet alerts, shows tray banner + startUpdate on install)
       │    + manual-update notice box
       └─ AboutPaneController
            ├─ App icon + name + version + copyright
            ├─ Website link (space-rabbit.app)
            └─ Author links (github.com/tahul, valeriansaliou.name)

All panes subclass `SettingsPaneViewController` (shared row/group/switch builders,
bold pane header, `resizePaneToFit()`). Setting groups are borderless rounded `NSBox`
cards (`.quaternarySystemFill`) — native primitives only, no custom-drawn controls.
`SettingsWindowController.shared.show(pane:)` deep-links to a pane (used by the menu
bar's launch-at-login warning, which also sets
`AutoStartPaneController.pendingLaunchAtLoginAlert` to flash the banner).

**Accent color:** the app follows the user's system accent everywhere — do not
hand-tint controls and do not set the per-app `AppleAccentColor` preference (it was
tried and reverted; `main.swift` removes a leftover key from older builds at launch).
`NSSwitch` has no tint API at all — a SwiftUI Toggle with `.tint` was tried for the
menu header's master switch and reverted (the tint did not render in the menu). The
switch's graphite-when-inactive problem is solved by `MenuKeyAppearanceView` (see the
UI tree above), not by tinting.

**Settings window & Spaces:** do NOT set `.moveToActiveSpace` on the settings
window's `collectionBehavior` (tried and reverted): the window server re-inserts
such windows at the back of the stacking order on every space transition, so the
window resurfaced behind other apps' windows when returning to its space. Plain
`makeKeyAndOrderFront` + `NSApp.activate` gives the platform-default behavior
(a window left open on another space pulls the user back there when re-shown).
```

Custom controls: `LinkTextField` / `LinkButton` — subclasses that override `resetCursorRects()` to show a pointing-hand cursor.

### Dock instant-hide feature (GeneralViewController)

Writes `autohide-time-modifier` to `com.apple.dock` preferences:
- Enable: set to `0.0` (instant)
- Disable/reset: remove the key (restore system default)
- Requires `CFPreferencesAppSynchronize` + `killall Dock` to take effect
- Shows a confirmation alert before restarting the Dock
- "Reset to system default" link appears when the key is overridden

## Localization

> [!IMPORTANT]
> **No user-visible string may be hardcoded in Swift, and every string must exist
> in _every_ language.** Adding one means editing `en.lproj` **and each other
> `<lang>.lproj`** in the same change. `make build` fails otherwise — that is
> deliberate, so an untranslated string can never ship. Do not work around the
> validator by deleting a language or skipping a key.

Standard macOS `.lproj` bundle localization — no Xcode string catalogs
(`.xcstrings` would need `xcstringstool` from Xcode's build system; the plain
`.strings` tables here are copied into the bundle verbatim by the `Makefile`).

Seven shipped languages — `en` (development language), `fr`, `es`, `de`, `pt`,
`zh-Hans`, `ru`. Each is one `.lproj` holding the same three files:

```
App/Resources/
  en.lproj/                    ← development language, defines the key set
    Localizable.strings        — all UI strings (the table L() reads)
    Localizable.stringsdict    — plural-sensitive strings only
    InfoPlist.strings          — localized Info.plist values
  fr.lproj/ es.lproj/ de.lproj/ pt.lproj/ zh-Hans.lproj/ ru.lproj/
    ...                        ← same three files, same keys,
                                 nothing more, nothing less
```

**Language code choices** (verified against `Bundle.preferredLocalizations`):

| Code | Also matches | Notes |
|---|---|---|
| `zh-Hans` | `zh-Hans-CN`, `zh-CN`, `zh` | Apple's script-based code. Traditional (`zh-Hant-TW`, `zh-HK`) deliberately does **not** match and falls back to English — add `zh-Hant.lproj` to support it. Legacy `zh_CN` naming also resolves but cannot express the Simplified/Traditional split |
| `pt` | `pt-BR`, `pt-PT` | Bare code on purpose, so one table serves both. Wording avoids the terms where the variants diverge. Split into `pt-BR.lproj` / `pt-PT.lproj` if they ever need to differ — the region-specific table then wins |
| `es` | `es-ES`, `es-MX`, `es-419` | Neutral wording, neither Peninsular- nor Latin American-specific |
| `de` | `de-DE`, `de-AT`, `de-CH` | |
| `fr` | `fr-FR`, `fr-CA`, `fr-BE`, `fr-CH` | |

**Per-language typography** (keep it when editing):

- **French** — `\U00A0` before `: ; ! ?` and inside `« … »`; apostrophe `’` not `'`.
  The escape is used rather than a literal U+00A0 so the file stays reviewable in a diff.
- **German** — `„ … “` quotation marks.
- **Spanish / Portuguese** — `“ … ”`; Spanish keeps its opening `¿`.
- **Simplified Chinese** — fullwidth punctuation (`：` `“ ”` `？`), no space before a
  colon, no space between a number and its measure word (`1,204 次切换`).
- **Russian** — `« … »` with **no** spaces inside (unlike French).

**Sidebar label budget.** `settings.pane.*` strings are also the sidebar rows,
which truncate with an ellipsis inside the fixed `Layout.sidebarWidth` (165 pt).
Measured empirically: **94.8 pt renders in full, 101.2 pt truncates** at 13 pt
system font, so keep new pane titles at or under ~95 pt. That is why several
languages use a shortened title (`Inicio auto.`, `Funções`, `Дополнения`) rather
than the literal translation. Raising `Layout.sidebarWidth` is the alternative if
a future language cannot fit.

### Reading a string

`App/Localization.swift` exposes exactly one lookup function:

```swift
L("menu.quit")                                  // plain
L("common.version", version)                    // %@ substitution
L("stats.switches", count, formattedCount)      // plural (stringsdict)
```

- **Keys must be string literals at the call site.** The validator scans for
  `L("…")` textually; a key held in a variable is invisible to it and will be
  reported as an unused key.
- `L` returns the key itself when nothing declares it — harmless at runtime, and
  the build-time check makes it unreachable.
- Key naming: `area.subarea.thing`, lowerCamelCase leaves
  (`settings.advanced.dockRestart.confirm`). `app.*` and `common.*` are the
  shared namespaces; reuse `common.ok` / `common.cancel` / `common.later` /
  `common.tryAgain` rather than adding another "OK".

### Language selection

Entirely the bundle loader's job — there is no in-app language setting and no
locale plumbing. macOS picks the `.lproj` matching the user's preferred language
when one is shipped, and otherwise falls back to `CFBundleDevelopmentRegion`
(`en`, set in `Info.plist`). Verified end-to-end: a French system resolves
`fr.lproj`, a German system falls back to `en.lproj` until `de.lproj` exists.

### Plurals

Count-dependent wording goes in `Localizable.stringsdict`, never in
`Localizable.strings` with an `== 1` ternary in Swift. Russian is the proof: it
needs **four** forms (`1 переключение`, `2 переключения`, `5 переключений`,
`21 переключение`), which no ternary can produce. Chinese needs only `other`;
each language declares exactly the categories CLDR gives it, and a missing
category falls back to `other`. Entries take the count **twice**: `%1$…`
selects the plural category, `%2$@` is the same count pre-formatted by
`NumberFormatter` (so the locale's grouping separator survives) and is what gets
displayed.

Unit names for durations are **not** in the tables at all: `localizedDuration()`
uses `DateComponentsFormatter`, so "2 days, 5 hr" comes from the system already
translated and pluralized in every language.

### Not localized (on purpose)

Proper nouns and technical text: author names and `space-rabbit.app` in the About
pane (inline in `Settings.swift`), the `"—"` placeholder for a missing version
string, and every `fputs`/`print` diagnostic — those are developer-facing logs,
so they stay English. The product name itself is the `app.name` key, to be
transliterated but not translated.

### What `make build` enforces

`Tools/Localization/Validate.swift`, run by the `verify-localizations` target
(~0.5 s). Any one of these fails the build:

1. A `.lproj` is missing a table file that `en.lproj` has — or has an extra one.
2. A key is missing from a language, or exists in a language but not in English.
3. A translation's format specifiers don't match English's (compared as a
   multiset, so `%1$@`/`%2$@` reordering for word order is allowed — dropping or
   inventing a `%@` is not).
4. A `.strings` file doesn't parse. Worth breaking the build over: a stray
   missing semicolon otherwise degrades silently to raw keys on screen.
5. A key is used by the code but undeclared, or declared but never used.

Plural *categories* are intentionally not compared across languages — each
language declares the ones its rules define.

## Changelog format

When asked to generate a changelog (typically between two git tags), follow these rules exactly:

- **Do not wrap lines.** No 80-column padding, no manual line breaks inside an entry — one entry is one long line.
- **Section titles are always `###` (H3).**
- **List items always use `-`**, never `*`.
- **Section wording is one of:** `Added`, `Fixed`, `Changed`, `Miscellaneous`, `Breaking`. Nothing else.
- **Every entry is `**Subject**: explanation`** — the subject in bold, followed by a colon and the explanation.
- **Always link the PR/issue** as a short `#ID` link in parentheses at the end of the entry.
- **Credit community contributors only** — append `thanks @handle` for outside contributors and issue reporters. The project's own authors (@tahul, @valeriansaliou) are never thanked for their own work; if an entry involves only them, the parentheses hold just the `#ID` link(s).
- **Keep it short and non-technical.** The audience is end users, not developers. One or two sentences per entry, describing what they will notice — not the internals. No mention of event taps, gesture phases, private APIs, timing windows, globals or file names. If an entry needs a paragraph to explain, it is being written for the wrong reader.

Example:

```markdown
### Fixed

- **Trackpad swipes**: swiping between spaces could jump two spaces at once or go the wrong way. ([#23](https://github.com/Tahul/space-rabbit/issues/23), [#22](https://github.com/Tahul/space-rabbit/pull/22), thanks @srajangarg)
- **Menu bar icon**: the icon no longer reappears after a restart when it was hidden. ([#31](https://github.com/Tahul/space-rabbit/issues/31))
```

Source the entries from `git log <tagA>..<tagB>`, folding a fix and its own follow-up correction into a single entry rather than narrating the intermediate state. A `chore:` commit that changes user-visible strings belongs under `Changed`, not `Miscellaneous`.

## Build system

Everything goes through the `Makefile`. No Xcode project.

| Target | What it does |
|---|---|
| `make build` | Compiles `App/*.swift` → `spacerabbit` binary, then verifies the min-macOS target and the localization tables (see "Localization") |
| `make assets` | Regenerates both build-time assets: `Tools/Icon/AppIcon.icns` (from `Tools/Icon/CreateIcon.swift`) and `Tools/Dmg/Background.tiff` (from `Tools/Dmg/CreateBackground.swift`) |
| `make app` | `build` + assembles `Space Rabbit.app` bundle + code-signs |
| `make app-dev` | `app` + kills any running instance + relaunches — **use this during development** |
| `make dmg` | `app` + creates the styled `Space-Rabbit.dmg` (see "DMG packaging") |
| `make notarize` | Submits DMG to Apple notarytool and staples the ticket |
| `make release` | `dmg` + `notarize` in sequence |
| `make clean` | Removes binary, icns, DMG background, and app bundle |

**During development, always use `make app-dev VERSION=0.0.0`** — the `VERSION=0.0.0` ensures the version is lower than any published release so the update checker never prompts. This target builds, kills the running instance, and relaunches in one step.

**Compiler flags:** `swiftc -O` (optimized, Swift 5 language mode — `Package.swift` pins `.swiftLanguageMode(.v5)` so LSP diagnostics match). Linked frameworks: CoreGraphics, CoreFoundation, ApplicationServices, AppKit, ServiceManagement.

**Version flow:** `git describe --tags --abbrev=0` → strips `v` prefix → `sed` replaces `__VERSION__` in `Info.plist` → app reads it at runtime via `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`.

**Signing:** credentials in `local.env` (git-ignored): `SIGN_ID`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. If `SIGN_ID` is empty, `make app` prompts interactively (or skips signing).

## DMG packaging

`make dmg` produces a styled installer window (700×460 pt content, 128 pt icons, app on
the left, `/Applications` symlink on the right, drag arrow in the background):

1. Stage `Space Rabbit.app`, the `Applications` symlink and `.background/background.tiff`
   into `Tools/Dmg/_staging` (`DMG_STAGING`). The intermediate read-write image is
   `Tools/Dmg/_writable.dmg` (`DMG_RW`). Both are git-ignored and deleted when the build
   ends; `make clean` removes them too.
2. Detach any leftover `/Volumes/Space Rabbit *` volume — a same-named volume would make
   ours mount under a suffixed name and the layout script would target the wrong disk.
3. `hdiutil create … -format UDRW` (sized `du` + 50 MB of slack) → mount read-write.
4. `osascript Tools/Dmg/Layout.applescript` drives Finder to set the window bounds, icon size,
   icon positions and background picture, then commits them to `.DS_Store`.
5. Copy `.VolumeIcon.icns` **after** the AppleScript — Finder consumes (deletes) that file
   when it absorbs it into the volume's custom-icon resource — then `SetFile -a C`.
6. Detach and `hdiutil convert` to compressed UDZO.

**Layout geometry lives in two places and must stay in sync**: the `DMG_*` variables in
the Makefile and the matching constants at the top of `Tools/Dmg/CreateBackground.swift`. The
Swift file draws the arrow into the gap between the two icon slots, so a changed slot
position silently misaligns the artwork.

**Finder quirks worth knowing:**
- Icon positions are in Finder coordinates: origin at the window content's top-left, y
  growing *downward*. The background generator flips into that convention.
- Finder's window `bounds` include the 28 pt title bar; `Layout.applescript` adds it back
  so the full background height is visible.
- The background is a HiDPI TIFF built by `tiffutil -cathidpicheck` from a 1× and a 2×
  PNG (both written at 72 dpi — tiffutil adds the HiDPI pairing itself). A 1×-only image
  works too but renders visibly soft on Retina.
- `NSImage.lockFocus` renders at the *display's* backing scale, which would double the
  PNG sizes on a Retina Mac; the generator draws into an explicit `NSBitmapImageRep`.

**Custom artwork:** the drawn background is a brand-neutral placeholder. Three ways to
replace it, in increasing order of effort:

1. **Drop in a PNG** (the normal path) — put a **1400×920 px** file (the @2x of the
   700×460 pt window; 700×460 px also works but looks soft on Retina) at
   `Tools/Dmg/BaseBackground.png`. `make assets` picks it up automatically via the
   `DMG_BACKGROUND_PNG` wildcard, resamples it to 1× and 2×, draws the overlay on top,
   and packs the HiDPI TIFF. A differently-sized PNG is a hard error, not a silent
   stretch. Use a different path with `make assets DMG_BACKGROUND_PNG=path/to/art.png`.
   The PNG supplies the canvas and the app-name title; everything positional (icon
   plates, drag arrow, subtitle) is drawn by `drawOverlay` so it tracks the slot
   constants instead of being baked in at a fixed spot.
2. **Supply a finished TIFF** — `make dmg DMG_BACKGROUND=path/to/art.tiff` bypasses the
   generator entirely.
3. **Edit `Tools/Dmg/CreateBackground.swift`** to change what gets drawn.

Any replacement must be 700×460 pt and leave the icon gap clear for the drawn arrow.

**Icon label legibility:** Finder draws the two icon labels in the *system* text color —
near-black in light mode — and exposes no property to change it (the scriptable
`icon view options` cover arrangement, icon size, text size, label position, item info
and background picture, nothing more). On the dark shipped artwork those labels would be
unreadable for light-mode users, so `drawOverlay` paints a 90%-white rounded plate behind
each one.

Finder owns the label layout, so the plate has to *predict* it. Two constants encode that
and must be re-measured off a real mount if either changes: `labelFontSize` mirrors the
`text size` set in `Layout.applescript`, and `labelBaselineGap` is the icon bottom edge →
text baseline distance. The plate is then centered on the text's optical center
(`baseline - capHeight/2`), not on the font's full line box — centering on the line box
reserves descender space under every label and visibly hangs the plate low. Width comes
from measuring the label string, so the two plates differ in width by design.

## Project layout

```
App/
  main.swift            — entry point: permissions, event tap, observers, run loop
  Localization.swift    — L() string lookup + localizedDuration()
  PrivateAPI.swift      — undocumented CGEvent fields, CGS types, dlsym resolution
  State.swift           — global runtime state, UserDefaults keys, persistence
  Shortcuts.swift       — reads macOS space-switch keyboard shortcuts
  SpaceSwitching.swift  — space queries, synthetic gesture posting, navigation
  EventTap.swift        — CGEvent tap callback (Feature 1: instant switch,
                          plus the configurable cycle shortcut)
  ShortcutRecorder.swift — Preferences control that records the cycle shortcut
  AutoFollow.swift      — app-activation observer (Feature 2: auto-follow)
  SwipeIntercept.swift  — shared gesture tap for horizontal Space swipes and
                          Mission Control entry/dismissal
  MenuBar.swift         — SwoopMenu status item and dropdown menu
  Settings.swift        — preferences window (General + About tabs) — largest file
  UpdateCheck.swift     — GitHub release version checking
  UpdateInstall.swift   — automatic update download, DMG install, and restart
  Info.plist            — bundle metadata (version placeholder: __VERSION__)
  Resources/            — localization tables, copied into the bundle as-is
    en.lproj/           — Localizable.strings + .stringsdict + InfoPlist.strings
    fr.lproj/ es.lproj/ de.lproj/ pt.lproj/ zh-Hans.lproj/ ru.lproj/
                        — same three files, same keys (enforced by the build)
Tools/                  — build-time asset generators (not compiled into the app)
  Localization/
    Validate.swift      — cross-language key check run by `make build`
  Icon/
    AppIcon.icns        — compiled icon (git-ignored, regenerated by `make assets`)
    CreateIcon.swift    — generates the icns programmatically
  Dmg/
    BaseBackground.png  — optional custom source artwork, 1400x920 px (tracked if present)
    Background.tiff     — final installer artwork (git-ignored, `make assets`)
    CreateBackground.swift — generates the 1x/2x background programmatically
    Layout.applescript  — drives Finder to lay out the mounted DMG window
Makefile
Package.swift           — LSP stub only, NOT used for building
README.md
CLAUDE.md               — this file
local.env               — git-ignored; signing credentials
.gitignore              — ignores .app, .dmg, binary, .build/, local.env, generated artwork
```

## Coding conventions

- **No hardcoded user-visible strings** — every one goes through `L("key")` and must be declared in *all* `.lproj` tables (see "Localization"). Developer-facing `fputs`/`print` diagnostics stay in English.
- **Globals prefixed `g`** — all mutable runtime state (e.g. `gEnabled`, `gTap`).
  Globals are main-thread-owned unless their declaration explicitly confines
  them to a serial queue; the Mission Control animator is the sole exception.
- **Constants prefixed `k`** — named magic numbers (e.g. `kSLSSpaceTypeAll`, `kInstantSwitchVelocity`).
- **Enums for grouping constants** — `Defaults` (UserDefaults keys), `CarbonModifier` (bitmasks), `Layout` (UI sizing), `ToggleColors`.
- **`MARK` sections** — every file uses `// MARK: -` with descriptive headers.
- **Doc comments** — `///` with `- Parameter:` and `- Returns:` annotations on all public/internal functions.
- **Private API isolation** — all undocumented symbols confined to `PrivateAPI.swift`. Other files use typed function pointers and named constants.
- **UI built programmatically** — no nibs, storyboards, or SwiftUI. All views use `NSStackView` + Auto Layout. (A SwiftUI `Toggle` hosted in `NSHostingView` was tried for the menu header's master switch to get a tinted on-state, and reverted: the `.tint` did not render in the menu context.)
- **C-compatible callbacks** — `eventTapCallback` and `onSignal` are global functions (not methods/closures) because their APIs require C function pointers.

## Known limitations

- Trackpad swipe gestures animate unless the opt-in "Instant Trackpad Swipe"
  feature is enabled (they bypass the keyboard event tap; Feature 3 intercepts
  them with its own gesture tap).
- Mission Control entry and dismissal, App Exposé entry and dismissal, and
  horizontal space navigation inside the Mission Control overview remain native
  unless the independent opt-in "Instant Mission Control" feature is enabled.
  They then follow the shared transition-speed slider; unrelated in-overview
  gestures remain native. That toggle covers the trackpad gesture for all of
  them, plus the dedicated Mission Control key and the "Mission Control" system
  hotkey — but not Show Desktop by any trigger, and not App Exposé by keyboard
  (only by trackpad; see the keyboard-trigger note above).
- Inside the Mission Control overview, only the one-step "Move left/right a
  space" bindings are converted to the segmented carousel stream. "Switch to
  Desktop N" and the cycle shortcut are multi-step and still stand down to
  macOS (animated) — see "Space shortcuts inside the overview".
- Space switches inside App Exposé or Show Desktop are left to macOS (animated).
- A reversed gesture is undone by posting the inverse transition, not by
  scrubbing the replacement backwards under the fingers: the transition is
  already committed by then, so there is nothing left to follow. A reversal
  therefore reads as a second transition at the slider's speed rather than as
  macOS's continuous rubber-banding.
- Synthetic DockSwipe gestures carry no display information — the Dock applies them to the display under the cursor. For a target space on a *different* display: at the "Instant" speed setting, `switchOnOtherDisplay` warps the cursor to that display, posts the gesture, and restores the cursor after `kCursorWarpRestoreDelay` (skipping the restore if the user moved it); at animated speeds it stands down and macOS's native animated switch handles it. Direct APIs are not an option (see the `CGSManagedDisplaySetCurrentSpace` warning above).
- Uses undocumented CGEvent fields and private CGS symbols — may break on macOS updates. macOS 27 already did this once: it rejects bare synthetic DockSwipe events, requiring the augmented path (see "macOS 27+ gesture augmentation").
- The macOS 27+ augmented path always posts the equivalent of an instant switch at the "Instant" slider setting; the animated velocity band (Fast/Faster/Fastest) is passed through but uncalibrated on macOS 27.
