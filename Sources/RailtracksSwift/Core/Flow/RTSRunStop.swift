//
//  RTSRunStop.swift
//  RailtracksSwift
//

import Foundation
import Synchronization

/// Why one run was stopped, shared by everything in that run.
///
/// A stop from inside the run, the flow's timeout or a node failing under `endOnError`, cancels the
/// run's work like a user cancel does, so a node seeing cancellation can't tell them apart. Whoever
/// stops the run records the reason here first, and normalization reads it back: anything thrown
/// while cancelled becomes `runTerminated(reason: reason ?? .cancelled)`. One per run, held by that
/// run's `RTSNodeInvoker`. See `docs/flow-timeout.md`.
final class RTSRunStop: Sendable {
    private typealias Listener = CheckedContinuation<Void, Never>

    private struct State {
        var reason: RTSRunTerminationReason?
        /// The one task waiting in `stopRequested()`: `RTSFlow`'s listener, which cancels the work.
        var listener: Listener?
        var isListenerCancelled = false
    }

    /// Whether a node failure stops the run: the run's `endOnError`, as it read it when it started.
    let endsOnError: Bool
    private let state = Mutex(State())

    init(endsOnError: Bool = false) {
        self.endsOnError = endsOnError
    }

    /// The first stop requested, or `nil` when nothing inside the run asked to stop it. `nil` does
    /// not mean the run succeeded: a user cancel isn't recorded here (it comes from outside, as plain
    /// task cancellation), and neither is an ordinary failure without `endOnError`.
    var reason: RTSRunTerminationReason? {
        state.withLock { $0.reason }
    }

    /// Records `reason` unless a stop was already requested, then wakes the listener so it cancels
    /// the run's work. The first stop wins. Returns whether this request was the one recorded.
    @discardableResult
    func request(_ reason: RTSRunTerminationReason) -> Bool {
        let (recorded, listener) = state.withLock { state -> (Bool, Listener?) in
            guard state.reason == nil else {
                return (false, nil)
            }
            state.reason = reason
            let listener = state.listener
            state.listener = nil
            return (true, listener)
        }
        // Resumed outside the lock: resuming runs no code inline, but it never needs to be inside.
        listener?.resume()
        if !recorded {
            log.debug("🛑 run already stopping; ignoring later stop \(reason)")
        }
        return recorded
    }

    /// Called by `invokeCore` with a node's final error. Under `endOnError` this stops the run,
    /// unless the error is itself a stop: the nodes a stop cuts short must not trigger another.
    func nodeFailed(name: String, error: Error) {
        guard endsOnError, RTSRunCancellation.terminationReason(of: error) == nil else {
            return
        }
        if request(.endOnError(nodeName: name, underlying: error)) {
            log.info("🛑 [\(name)] failed with endOnError set; stopping the run: \(error)")
        }
    }

    /// Returns once a stop has been requested, or as soon as the calling task is cancelled. Meant for
    /// a single listener, `RTSFlow`'s, which cancels the run's work when it returns.
    func stopRequested() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumesNow = state.withLock { state -> Bool in
                    if state.reason != nil || state.isListenerCancelled {
                        return true
                    }
                    state.listener = continuation
                    return false
                }
                if resumesNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            // May run before the continuation is stored; the flag covers that order.
            let listener = state.withLock { state -> Listener? in
                state.isListenerCancelled = true
                let listener = state.listener
                state.listener = nil
                return listener
            }
            listener?.resume()
        }
    }
}
