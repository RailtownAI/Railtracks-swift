//
//  RTSRAGAssetRequest.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-10-21.
//

import Foundation
import NaturalLanguage
import Synchronization

/// One in-flight `NLContextualEmbedding.requestAssets()` call, shared by every caller waiting for
/// the same model asset.
///
/// Exists because the request offers nothing to bound it by: no progress, no cancellation, and on
/// a Simulator, sometimes no answer at all. Awaiting it directly can therefore wait forever, and a
/// `withThrowingTaskGroup` race against a sleep does not help, since a task group waits for all of
/// its children. So the request runs once, unstructured, and each caller waits on it through its
/// own continuation, which a timeout or the caller's cancellation can resume without it.
///
/// **One per asset per process**, not per embedder: an app with one embedder per index would
/// otherwise start one request per index, and a Simulator would collect one hung request per
/// retry. A caller that stops waiting leaves the request running, so a later caller joins it — what
/// makes "let me wait it out" work after a timeout. A request that never answers stays registered
/// until the process exits, which is the price of not stacking new ones.
///
/// See `docs/apple-embedding-prepare.md`.
internal final class RTSRAGAssetRequest: Sendable {

    typealias Outcome = NLContextualEmbedding.AssetsResult

    private struct Waiter {
        let continuation: CheckedContinuation<Outcome?, Error>
        let timer: Task<Void, Never>?
    }

    private struct State {
        var outcome: Result<Outcome, Error>?
        var waiters: [UUID: Waiter] = [:]
    }

    private static let inFlight = Mutex<[String: RTSRAGAssetRequest]>([:])

    private let key: String
    private let state = Mutex(State())

    private init(key: String) {
        self.key = key
    }

    /// The request in flight for `key`, or a new one running `start`.
    ///
    /// - Parameters:
    ///   - key: Which asset. Callers sharing a key share one request, so it names the asset, not
    ///     anything layered on top of it such as pooling.
    ///   - start: Performs the request. Runs at most once per request, detached from the caller, so
    ///     the caller's cancellation never reaches it.
    static func shared(
        key: String,
        start: @escaping @Sendable () async throws -> Outcome
    ) -> RTSRAGAssetRequest {
        inFlight.withLock { requests in
            if let existing = requests[key] {
                return existing
            }
            let request = RTSRAGAssetRequest(key: key)
            requests[key] = request
            // Created inside the lock, so the request is registered before it can finish and
            // unregister itself. Creating a task runs none of its body, so no foreign code runs
            // under the lock.
            Task.detached {
                await request.run(start)
            }
            return request
        }
    }

    /// Waits for the request's outcome, up to `timeout`.
    ///
    /// - Parameter timeout: `nil` waits as long as it takes. Zero or negative does not wait.
    /// - Returns: The outcome, or `nil` when `timeout` passed first. The request keeps running
    ///   either way.
    /// - Throws: `CancellationError` when the caller is cancelled first, or whatever the request
    ///   threw.
    func wait(timeout: Duration?) async throws -> Outcome? {
        if let finished = state.withLock({ $0.outcome }) {
            return try finished.get()
        }
        if let timeout, timeout <= .zero {
            return nil
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolved = state.withLock { state -> Result<Outcome?, Error>? in
                    if let outcome = state.outcome {
                        return outcome.map { $0 }
                    }
                    // Checked under the lock the cancellation handler also takes, so a caller
                    // cancelled before registering is resumed here, and one cancelled after is
                    // found and resumed by the handler. Neither can slip between the two.
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    let timer = timeout.map { timeout in
                        Task {
                            try? await Task.sleep(for: timeout)
                            guard !Task.isCancelled else {
                                return
                            }
                            self.resume(waiterID, with: .success(nil))
                        }
                    }
                    state.waiters[waiterID] = Waiter(continuation: continuation, timer: timer)
                    return nil
                }
                if let resolved {
                    continuation.resume(with: resolved)
                }
            }
        } onCancel: {
            resume(waiterID, with: .failure(CancellationError()))
        }
    }

    /// A readable name for `outcome`, for logs and error reasons. The enum's own description is
    /// an opaque raw value.
    static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .available:
            return "available"
        case .notAvailable:
            return "notAvailable"
        case .error:
            return "error"
        @unknown default:
            return "unknown (\(outcome.rawValue))"
        }
    }

    // MARK: - Internals

    private func run(_ start: @Sendable () async throws -> Outcome) async {
        ragLog.info("📚 requesting on-device assets for \(key)")
        let outcome: Result<Outcome, Error>
        do {
            outcome = .success(try await start())
        } catch {
            outcome = .failure(error)
        }
        switch outcome {
        case .success(let result):
            ragLog.info("📚 asset request for \(key) finished: \(Self.describe(result))")
        case .failure(let error):
            ragLog.warning("📚 asset request for \(key) failed: \(error)")
        }

        // Unregistered first, so a caller arriving from here on starts a fresh request — after
        // `.notAvailable` or `.error`, asking again is the only way to find out if that changed.
        Self.inFlight.withLock { requests in
            if requests[key] === self {
                requests[key] = nil
            }
        }
        let waiters = state.withLock { state in
            state.outcome = outcome
            let waiters = state.waiters
            state.waiters = [:]
            return waiters
        }
        for waiter in waiters.values {
            waiter.timer?.cancel()
            waiter.continuation.resume(with: outcome.map { $0 })
        }
    }

    /// Resumes one waiter, if it is still waiting. Whichever of the request, the timer and the
    /// cancellation handler gets here first wins; the others find nothing to resume.
    private func resume(_ waiterID: UUID, with result: Result<Outcome?, Error>) {
        // Resumed outside the lock, the rule `RTSRAGRateGovernor` follows: a continuation runs
        // its caller's code, and none of that belongs under a non-reentrant lock.
        let waiter = state.withLock { $0.waiters.removeValue(forKey: waiterID) }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(with: result)
    }
}
