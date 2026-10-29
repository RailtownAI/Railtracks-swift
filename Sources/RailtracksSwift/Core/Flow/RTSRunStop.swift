//
//  RTSRunStop.swift
//  RailtracksSwift
//

import Foundation
import Synchronization

/// Why one run was stopped, shared by everything in that run.
///
/// A stop from inside the run, such as the flow's timeout, cancels the run's work like a user cancel
/// does, so a node seeing cancellation can't tell the two apart. Whoever stops the run records the
/// reason here first, and normalization reads it back: anything thrown while cancelled becomes
/// `runTerminated(reason: reason ?? .cancelled)`. One per run, held by that run's `RTSNodeInvoker`.
/// See `docs/flow-timeout.md`.
final class RTSRunStop: Sendable {
    private let recordedReason = Mutex<RTSRunTerminationReason?>(nil)

    /// The first stop requested, or `nil` when nothing inside the run asked to stop it. `nil` does
    /// not mean the run succeeded: a user cancel isn't recorded here (it comes from outside, as plain
    /// task cancellation), and neither is an ordinary failure.
    var reason: RTSRunTerminationReason? {
        recordedReason.withLock { $0 }
    }

    /// Records `reason` unless a stop was already requested; the first stop wins. Returns whether
    /// this request was the one recorded.
    @discardableResult
    func request(_ reason: RTSRunTerminationReason) -> Bool {
        let recorded = recordedReason.withLock { current in
            guard current == nil else {
                return false
            }
            current = reason
            return true
        }
        if !recorded {
            log.debug("🛑 run already stopping; ignoring later stop \(reason)")
        }
        return recorded
    }
}
