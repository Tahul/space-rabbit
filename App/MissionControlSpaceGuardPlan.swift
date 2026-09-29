/*
 * MissionControlSpaceGuardPlan.swift — Decision logic for the macOS 27
 * Mission Control Space guard
 *
 * A synthetic vertical transition can rarely leave the user on another Space
 * (about one in 300 scripted closes on 26A428). Kept free of AppKit so the
 * ordering of arrival, input and settling can be replayed without driving the
 * user's desktop.
 */

import Foundation

/// Watches one synthetic Mission Control transition and decides whether an
/// unexplained Space change should be undone.
struct MissionControlSpaceGuardState {
    enum Action: Equatable {
        /// Keep watching.
        case wait
        /// Return to these spaces, which the transition left.
        case restore([UInt64])
        /// Stop watching without acting.
        case finish
    }

    /// How long after the transition an unexplained change is attributed to it.
    /// Scripted runs observed the change within the 0.8 s settle they allowed.
    static let kLifetime: TimeInterval = 1.5

    let before: [UInt64]
    private let startedAt: TimeInterval
    private var finished = false

    /// - Parameters:
    ///   - before: Current spaces across displays when the transition was posted.
    ///   - startedAt: Monotonic time of posting.
    init(before: [UInt64], startedAt: TimeInterval) {
        self.before = before
        self.startedAt = startedAt
    }

    /// Advances the watch by one observation.
    ///
    /// - Parameters:
    ///   - now: Monotonic time of this observation.
    ///   - current: Current spaces across displays.
    ///   - overviewOpen: Whether an overview is still on screen. Only consulted
    ///     once `current` differs from `before`.
    ///   - inputUnchanged: `false` once the user has typed, clicked or scrolled.
    ///   - selfNavigated: `true` when Space Rabbit itself started navigation
    ///     (auto-follow) during the watch.
    /// - Returns: What to do next. `.restore` and `.finish` end the watch.
    mutating func step(now: TimeInterval, current: [UInt64], overviewOpen: Bool,
                       inputUnchanged: Bool, selfNavigated: Bool) -> Action {
        guard !finished else { return .finish }
        guard inputUnchanged, !selfNavigated, !before.isEmpty, !current.isEmpty,
              now - startedAt <= Self.kLifetime else {
            finished = true
            return .finish
        }
        // Unchanged, or still settling behind the overview: keep watching.
        guard current != before, !overviewOpen else { return .wait }

        finished = true
        let left = before.filter { !current.contains($0) }
        return left.isEmpty ? .finish : .restore(left)
    }
}
