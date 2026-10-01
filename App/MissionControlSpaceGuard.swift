/*
 * MissionControlSpaceGuard.swift — Returns to the original Space when a
 * synthetic macOS 27 Mission Control transition lands elsewhere
 *
 * The cause lives inside WindowManager and was not found; this only bounds
 * the damage. User input or auto-follow during the watch means the change
 * was wanted, so the guard stands down: clicks and scrolls via the input
 * counters below, key presses via EventTap, physical gestures via
 * SwipeIntercept.
 */

import AppKit
import os

/// Poll cadence while a watch is outstanding. At most 30 polls per transition.
private let kMissionControlSpaceGuardPollInterval: TimeInterval = 0.05

private let missionControlGuardLog = Logger(subsystem: "app.spacerabbit",
                                            category: "MissionControlGuard")

/// Inputs that mean the user acted after the transition was posted.
private func missionControlGuardInputCounts() -> [UInt32] {
    [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].map {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
    }
}

/// One outstanding watch. Main thread only; identity invalidates callbacks
/// from superseded watches.
private final class MissionControlSpaceGuardRequest {
    var state: MissionControlSpaceGuardState
    let inputCounts = missionControlGuardInputCounts()
    let autoFollowTarget = gAutoFollowTargetSpace

    init(before: [CGSSpaceID]) {
        state = MissionControlSpaceGuardState(before: before,
                                              startedAt: ProcessInfo.processInfo.systemUptime)
    }
}

private var gMissionControlSpaceGuard: MissionControlSpaceGuardRequest?

/// Starts watching the Space layout after a synthetic vertical transition.
/// A later transition replaces the watch with its own baseline.
///
/// - Parameter before: Current spaces captured just before posting.
func armMissionControlSpaceGuard(_ before: [CGSSpaceID]) {
    let request = MissionControlSpaceGuardRequest(before: before)
    gMissionControlSpaceGuard = request
    scheduleMissionControlSpaceGuardCheck(request)
}

/// Abandons the watch when the user presses a key or starts a physical gesture.
func cancelMissionControlSpaceGuard() {
    gMissionControlSpaceGuard = nil
}

private func scheduleMissionControlSpaceGuardCheck(_ request: MissionControlSpaceGuardRequest) {
    DispatchQueue.main.asyncAfter(deadline: .now() + kMissionControlSpaceGuardPollInterval) {
        checkMissionControlSpaceGuard(request)
    }
}

private func checkMissionControlSpaceGuard(_ request: MissionControlSpaceGuardRequest) {
    guard gMissionControlSpaceGuard === request else { return }

    let current = getAllCurrentSpaces()
    let changed = current != request.state.before
    let inputUnchanged = request.inputCounts == missionControlGuardInputCounts()
    let selfNavigated = gAutoFollowTargetSpace != 0
        && gAutoFollowTargetSpace != request.autoFollowTarget
    let before = String(describing: request.state.before)
    let after = String(describing: current)

    switch request.state.step(now: ProcessInfo.processInfo.systemUptime,
                              current: current,
                              // The window-list scan only runs once something moved.
                              overviewOpen: changed && isMissionControlActive(),
                              inputUnchanged: inputUnchanged,
                              selfNavigated: selfNavigated) {
    case .wait:
        scheduleMissionControlSpaceGuardCheck(request)
    case .restore(let spaces):
        gMissionControlSpaceGuard = nil
        for space in spaces {
            let result = switchToSpace(space)
            missionControlGuardLog.notice(
                "Unexpected Space change after Mission Control \(before, privacy: .public) -> \(after, privacy: .public); restoring \(space, privacy: .public): \(String(describing: result), privacy: .public)")
        }
    case .finish:
        gMissionControlSpaceGuard = nil
        if changed {
            missionControlGuardLog.notice(
                "Space change after Mission Control left alone \(before, privacy: .public) -> \(after, privacy: .public); input=\(!inputUnchanged, privacy: .public) autoFollow=\(selfNavigated, privacy: .public)")
        }
    }
}
