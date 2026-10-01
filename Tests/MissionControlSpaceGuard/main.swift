import Foundation

private var gChecks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    gChecks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

typealias Guard = MissionControlSpaceGuardState

// The scripted failure: 7 -> 6 after a synthetic close, no input.
var landed = Guard(before: [7], startedAt: 0)
check(landed.step(now: 0.05, current: [7], overviewOpen: false,
                  inputUnchanged: true, selfNavigated: false) == .wait, "watch an unchanged layout")
check(landed.step(now: 0.30, current: [6], overviewOpen: false,
                  inputUnchanged: true, selfNavigated: false) == .restore([7]), "restore the left Space")
check(landed.step(now: 0.35, current: [6], overviewOpen: false,
                  inputUnchanged: true, selfNavigated: false) == .finish, "restore at most once")

// A change still behind the closing overview waits for it to settle.
var settling = Guard(before: [7], startedAt: 0)
check(settling.step(now: 0.10, current: [8], overviewOpen: true,
                    inputUnchanged: true, selfNavigated: false) == .wait, "wait for the overview to close")
check(settling.step(now: 0.20, current: [8], overviewOpen: false,
                    inputUnchanged: true, selfNavigated: false) == .restore([7]), "then restore")

// Wanted changes are left alone: user input, auto-follow, or a late change.
for (input, follow, time) in [(false, false, 0.2), (true, true, 0.2), (true, false, 1.6)] {
    var wanted = Guard(before: [7], startedAt: 0)
    check(wanted.step(now: time, current: [6], overviewOpen: false,
                      inputUnchanged: input, selfNavigated: follow) == .finish,
          "leave a wanted change alone (input \(!input), follow \(follow), t \(time))")
}

// A clean transition ends at the lifetime without acting.
var clean = Guard(before: [7], startedAt: 0)
var time = 0.0
var action = Guard.Action.wait
while action == .wait, time < 3 {
    time += 0.05
    action = clean.step(now: time, current: [7], overviewOpen: false,
                        inputUnchanged: true, selfNavigated: false)
}
check(action == .finish && time > Guard.kLifetime, "expire after the lifetime")

// Multiple displays: only the display that moved is restored.
var displays = Guard(before: [3, 7], startedAt: 0)
check(displays.step(now: 0.3, current: [3, 6], overviewOpen: false,
                    inputUnchanged: true, selfNavigated: false) == .restore([7]), "restore only the moved display")

// An unreadable layout never triggers navigation.
var unreadable = Guard(before: [7], startedAt: 0)
check(unreadable.step(now: 0.1, current: [], overviewOpen: false,
                      inputUnchanged: true, selfNavigated: false) == .finish, "stand down on unreadable state")
var noBaseline = Guard(before: [], startedAt: 0)
check(noBaseline.step(now: 0.1, current: [6], overviewOpen: false,
                      inputUnchanged: true, selfNavigated: false) == .finish, "stand down without a baseline")

print("Mission Control Space guard: \(gChecks) checks passed")
