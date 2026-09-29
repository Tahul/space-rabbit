import Foundation

private var gChecks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    gChecks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// #72: native activation precedes arrival, then the destination's previous
// app takes focus 115 ms later. Merely seeing the target active is not success.
var captured = AutoFollowFocusState(pid: 1, startedAt: 0)
check(captured.step(now: 0.06, targetVisible: false, frontmostPID: 1,
                    inputUnchanged: true) == .wait, "wait for the destination")
check(captured.step(now: 0.08, targetVisible: true, frontmostPID: 1,
                    inputUnchanged: true) == .wait, "keep watching through arrival")
check(captured.appActivated(2, now: 0.115, targetVisible: true,
                            inputUnchanged: true), "consume the arrival activation")
check(captured.step(now: 0.12, targetVisible: true, frontmostPID: 2,
                    inputUnchanged: true) == .restore, "repair the captured focus loss")
check(captured.step(now: 0.15, targetVisible: true, frontmostPID: 2,
                    inputUnchanged: true) == .finish, "repair at most once")

// Timing variants from the live trace: a fixed 100 ms reactivation would run
// too early in several failures and needlessly touch the successful switches.
for lossTime in [0.067, 0.078, 0.105, 0.115, 0.151] {
    var state = AutoFollowFocusState(pid: 1, startedAt: 0)
    check(state.appActivated(2, now: lossTime, targetVisible: true,
                             inputUnchanged: true), "recognize arrival at \(lossTime)")
    check(state.step(now: lossTime + 0.01, targetVisible: true, frontmostPID: 2,
                     inputUnchanged: true) == .restore, "repair after \(lossTime)")
}

var successful = AutoFollowFocusState(pid: 1, startedAt: 0)
check(successful.step(now: 0.1, targetVisible: true, frontmostPID: 1,
                      inputUnchanged: true) == .wait, "allow normal activation to settle")
check(successful.step(now: 0.41, targetVisible: true, frontmostPID: 1,
                      inputUnchanged: true) == .finish, "never reactivate a successful switch")

// Preserve the original target across intermediate desktops in a long jump.
var multiStep = AutoFollowFocusState(pid: 1, startedAt: 0)
check(multiStep.appActivated(2, now: 0.05, targetVisible: false,
                             inputUnchanged: true, transitVisible: true), "consume intermediate arrival")
check(multiStep.step(now: 0.06, targetVisible: false, frontmostPID: 2,
                     inputUnchanged: true) == .wait, "do not restore on the intermediate desktop")
check(multiStep.appActivated(3, now: 0.1, targetVisible: true,
                             inputUnchanged: true), "recognize the final desktop's previous app")
check(multiStep.step(now: 0.12, targetVisible: true, frontmostPID: 3,
                     inputUnchanged: true) == .restore, "repair only on the final destination")

var inputInTransit = AutoFollowFocusState(pid: 1, startedAt: 0)
check(!inputInTransit.appActivated(2, now: 0.05, targetVisible: false,
                                   inputUnchanged: false, transitVisible: true), "new input also wins during transit")
check(inputInTransit.step(now: 0.12, targetVisible: true, frontmostPID: 3,
                          inputUnchanged: true) == .finish, "never resume after input in transit")

// A new Cmd-Tab or click can select exactly the app that arrival would have
// restored. PID alone cannot distinguish those cases: fresh input wins.
var nextChoice = AutoFollowFocusState(pid: 1, startedAt: 0)
check(!nextChoice.appActivated(2, now: 0.115, targetVisible: true,
                               inputUnchanged: false), "do not consume the user's next choice")
check(nextChoice.step(now: 0.12, targetVisible: true, frontmostPID: 2,
                      inputUnchanged: true) == .finish, "cancellation is permanent")

var clickDuringRepair = AutoFollowFocusState(pid: 1, startedAt: 0)
_ = clickDuringRepair.appActivated(2, now: 0.1, targetVisible: true, inputUnchanged: true)
check(clickDuringRepair.step(now: 0.12, targetVisible: true, frontmostPID: 2,
                             inputUnchanged: false) == .finish, "recheck input immediately before repair")

var navigatedAway = AutoFollowFocusState(pid: 1, startedAt: 0)
_ = navigatedAway.step(now: 0.1, targetVisible: true, frontmostPID: 1, inputUnchanged: true)
check(navigatedAway.step(now: 0.15, targetVisible: false, frontmostPID: 2,
                         inputUnchanged: true) == .finish, "never pull the user back to a departed space")

var beforeArrival = AutoFollowFocusState(pid: 1, startedAt: 0)
check(!beforeArrival.appActivated(2, now: 0.1, targetVisible: false,
                                  inputUnchanged: true), "unrelated activations before arrival are not ours")
check(beforeArrival.step(now: 0.2, targetVisible: true, frontmostPID: 2,
                         inputUnchanged: true) == .finish, "do not revive an abandoned follow")

var thirdApp = AutoFollowFocusState(pid: 1, startedAt: 0)
_ = thirdApp.appActivated(2, now: 0.1, targetVisible: true, inputUnchanged: true)
check(!thirdApp.appActivated(3, now: 0.11, targetVisible: true,
                             inputUnchanged: true), "do not fight an unrelated third app")
check(thirdApp.step(now: 0.12, targetVisible: true, frontmostPID: 3,
                    inputUnchanged: true) == .finish, "third-app activation cancels repair")

var nativeRecovery = AutoFollowFocusState(pid: 1, startedAt: 0)
_ = nativeRecovery.appActivated(2, now: 0.1, targetVisible: true, inputUnchanged: true)
check(!nativeRecovery.appActivated(1, now: 0.11, targetVisible: true,
                                   inputUnchanged: true), "target activation remains available to the echo guard")
check(nativeRecovery.step(now: 0.12, targetVisible: true, frontmostPID: 1,
                           inputUnchanged: true) == .wait, "leave native focus recovery alone")
check(nativeRecovery.step(now: 0.5, targetVisible: true, frontmostPID: 1,
                           inputUnchanged: true) == .finish, "finish without an AX write after native recovery")

var expired = AutoFollowFocusState(pid: 1, startedAt: 0)
check(!expired.appActivated(2, now: 1.51, targetVisible: true,
                            inputUnchanged: true), "late activation is not an arrival echo")
check(expired.step(now: 1.52, targetVisible: true, frontmostPID: 2,
                   inputUnchanged: true) == .finish, "bound the lifetime of a failed switch")

var noNotification = AutoFollowFocusState(pid: 1, startedAt: 0)
check(noNotification.step(now: 0.1, targetVisible: true, frontmostPID: 2,
                          inputUnchanged: true) == .wait, "a frontmost-app snapshot alone cannot authorize repair")
check(noNotification.step(now: 1.51, targetVisible: true, frontmostPID: 2,
                          inputUnchanged: true) == .finish, "missing notifications expire safely")

print("Auto-follow focus: \(gChecks) checks passed")
