//
//  RTSRunCancellation.swift
//  RailtracksSwift
//

import Foundation

/// How a cancelled run reports itself, in one place.
///
/// A run is cancelled by cancelling the Swift `Task` that awaits `RTSFlow.run`. Providers then
/// throw whatever they throw on cancel (`URLError.cancelled`, Conduit's own errors, Foundation
/// Models' errors, `CancellationError`), so a caller would otherwise see a different error per
/// provider. Everything thrown while the task is cancelled becomes one shape:
/// `RTSError.runTerminated(reason:)`, `.cancelled` unless the run recorded another reason on its
/// `RTSRunStop` (a timeout). See `docs/flow-timeout.md`.
enum RTSRunCancellation {

    /// `error` as the run should report it: `.runTerminated` when the current task has been
    /// cancelled, otherwise `error` unchanged.
    ///
    /// The reason is `stopReason`, what the run recorded when it stopped itself (its timeout), or
    /// `.cancelled` when nothing was recorded, meaning the app cancelled the task.
    ///
    /// A `CancellationError` thrown by the app's own code while the run was *not* cancelled passes
    /// through as itself, matching Python, which keeps a user's own `TimeoutError` apart from its
    /// global timeout. An error that already says how the run was stopped is kept, so the first
    /// stop observed is the one reported.
    static func normalized(
        _ error: Error,
        stopReason: RTSRunTerminationReason?,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> Error {
        guard Task.isCancelled else {
            return error
        }
        if case .runTerminated? = error as? RTSError {
            return error
        }
        let reason = stopReason ?? .cancelled
        log.debug("🛑 run stopped; reporting \(error) as runTerminated(reason: \(reason))")
        return RTSError.runTerminated(
            reason: reason,
            file: file,
            line: line,
            function: function
        )
    }

    /// Whether `error` is a run the app cancelled itself. Such a run is not a bug, so it is not
    /// sent to error reporting.
    static func isCancellation(_ error: Error) -> Bool {
        guard case .cancelled? = terminationReason(of: error) else {
            return false
        }
        return true
    }

    /// The reason the run was stopped, when `error` says it was; `nil` for any other error,
    /// including `nil` itself.
    static func terminationReason(of error: Error?) -> RTSRunTerminationReason? {
        guard case .runTerminated(let reason, _)? = error as? RTSError else {
            return nil
        }
        return reason
    }
}
