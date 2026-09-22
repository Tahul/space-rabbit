/*
 * AutoFollowFocus.swift — Bounded focus recovery for an auto-follow arrival
 *
 * Native activation can succeed before a synthetic Space switch restores
 * the destination's previous app. Keep the intended PID through that short
 * arrival window, without overriding a later user choice (#72).
 */

import Foundation

/// Tracks one follow independently of AppKit, so the ordering of activation,
/// arrival and new input can be replayed without driving the user's desktop.
struct AutoFollowFocusState {
    enum Action { case wait, restore, finish }

    /// Matches the maximum credible lifetime of an auto-follow Space change.
    private let deadline: TimeInterval
    private let pid: Int32
    private var arrivalTime: TimeInterval?
    private var displacedByPID: Int32?
    private var finished = false

    /// The destination's previous app can activate just after the Space first
    /// becomes visible. A momentarily correct PID is not yet a settled switch.
    private static let kArrivalSettleWindow: TimeInterval = 0.3

    /// A switch that never lands must not retain permission to refocus later.
    private static let kFollowLifetime: TimeInterval = 1.5

    /// Creates a request using monotonic time; wall-clock changes cannot
    /// extend a pending focus repair.
    init(pid: Int32, startedAt: TimeInterval) {
        self.pid = pid
        deadline = startedAt + Self.kFollowLifetime
    }

    /// Returns whether an activation is the fallout of this request's arrival
    /// and should be kept out of the ordinary auto-follow observer.
    mutating func appActivated(_ activatedPID: Int32, now: TimeInterval,
                               targetVisible: Bool, inputUnchanged: Bool,
                               transitVisible: Bool = false) -> Bool {
        guard !finished, now < deadline, inputUnchanged else {
            finished = true
            return false
        }
        guard activatedPID != pid else { return false }
        // A multi-step jump may activate the app on an intermediate desktop.
        // Consume that fallout without treating it as the final displacement.
        if !targetVisible, transitVisible, arrivalTime == nil { return true }
        guard targetVisible, displacedByPID == nil || displacedByPID == activatedPID else {
            finished = true
            return false
        }
        arrivalTime = arrivalTime ?? now
        displacedByPID = activatedPID
        return true
    }

    /// Decides whether to keep watching, perform one repair, or discard this
    /// request. Successful native activation never requires an AX write.
    mutating func step(now: TimeInterval, targetVisible: Bool,
                       frontmostPID: Int32?, inputUnchanged: Bool) -> Action {
        guard !finished, now < deadline, inputUnchanged else {
            finished = true
            return .finish
        }
        guard targetVisible else {
            if arrivalTime != nil {
                finished = true
                return .finish
            }
            return .wait
        }
        arrivalTime = arrivalTime ?? now

        if let displacedByPID, frontmostPID == displacedByPID {
            finished = true
            return .restore
        }
        if frontmostPID == pid, let arrivalTime,
           now - arrivalTime >= Self.kArrivalSettleWindow {
            finished = true
            return .finish
        }
        return .wait
    }
}
