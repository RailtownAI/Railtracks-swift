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
        /// Watches for the assets arriving, while anyone waits. See ``checkUntilFinished()``.
        var checkTask: Task<Void, Never>?
    }

    /// How a caller came by its request, for the log.
    private enum Registration {
        case started
        case joined
        case superseded
    }

    /// How often a waited-on request checks whether the assets have arrived.
    static let defaultCheckInterval: Duration = .seconds(2)

    /// How old a request may be and still be joined. Older, and the next caller asks again.
    static let defaultStaleAfter: Duration = .seconds(30)

    private static let inFlight = Mutex<[String: RTSRAGAssetRequest]>([:])

    private let key: String
    private let assetsArrived: @Sendable () -> Bool
    private let checkInterval: Duration
    private let startedAt = ContinuousClock.now
    private let state = Mutex(State())

    private init(
        key: String,
        assetsArrived: @escaping @Sendable () -> Bool,
        checkInterval: Duration
    ) {
        self.key = key
        self.assetsArrived = assetsArrived
        self.checkInterval = checkInterval
    }

    /// The request in flight for `key`, or a new one running `start`.
    ///
    /// **Apple's answer is not trusted alone.** On a device, offline, the request never answered
    /// and did not recover when the network returned; online, the model arrived while the request
    /// stayed silent. So a waited-on request also checks `assetsArrived`, and a request older than
    /// `staleAfter` is replaced rather than joined, so a retry asks iOS again.
    ///
    /// - Parameters:
    ///   - key: Which asset. Callers sharing a key share one request, so it names the asset, not
    ///     anything layered on top of it such as pooling.
    ///   - start: Performs the request. Runs at most once per request, detached from the caller, so
    ///     the caller's cancellation never reaches it.
    ///   - assetsArrived: Whether the assets are on the device now. Checked every `checkInterval`
    ///     while anyone waits; true resolves the request as `.available`, answered or not.
    ///   - checkInterval: How often to check `assetsArrived`.
    ///   - staleAfter: The age past which a request is replaced rather than joined.
    static func shared(
        key: String,
        start: @escaping @Sendable () async throws -> Outcome,
        assetsArrived: @escaping @Sendable () -> Bool = { false },
        checkInterval: Duration = RTSRAGAssetRequest.defaultCheckInterval,
        staleAfter: Duration = RTSRAGAssetRequest.defaultStaleAfter
    ) -> RTSRAGAssetRequest {
        let (request, registration) = inFlight.withLock { requests in
            let existing = requests[key]
            if let existing, ContinuousClock.now - existing.startedAt < staleAfter {
                return (existing, Registration.joined)
            }
            // A stale request is abandoned, not cancelled — it cannot be. Its waiters stay with it,
            // and its check still resolves them if the assets arrive.
            let request = RTSRAGAssetRequest(
                key: key,
                assetsArrived: assetsArrived,
                checkInterval: checkInterval
            )
            requests[key] = request
            // Created inside the lock, so the request is registered before it can finish and
            // unregister itself. Creating a task runs none of its body, so no foreign code runs
            // under the lock.
            Task.detached {
                await request.run(start)
            }
            return (request, existing == nil ? Registration.started : Registration.superseded)
        }
        // Logged, rather than left to the absence of a "requesting" line, so sharing is something
        // a manual test can see.
        switch registration {
        case .started:
            break
        case .joined:
            ragLog.info("📚 joining the in-flight asset request for \(key)")
        case .superseded:
            ragLog.info("📚 superseding a stale asset request for \(key)")
        }
        return request
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
                    // The first waiter starts the check; the last one to leave stops it.
                    if state.checkTask == nil {
                        state.checkTask = Task {
                            await self.checkUntilFinished()
                        }
                    }
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
        // Logged whether or not it still decides anything: the real answer, late or not, is what a
        // device investigation needs.
        switch outcome {
        case .success(let result):
            ragLog.info("📚 asset request for \(key) finished: \(Self.describe(result))")
        case .failure(let error):
            ragLog.warning("📚 asset request for \(key) failed: \(error)")
        }
        finish(with: outcome)
    }

    /// Checks for the assets every `checkInterval`, until they arrive or this task is cancelled —
    /// by the last waiter leaving, or by the request finishing.
    ///
    /// Only while someone waits, so a request nobody waits on, such as one that will never answer,
    /// costs nothing in the background.
    private func checkUntilFinished() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: checkInterval)
            guard !Task.isCancelled else {
                return
            }
            if assetsArrived() {
                if finish(with: .success(.available)) {
                    ragLog.info("📚 assets for \(key) appeared before the request answered")
                }
                return
            }
        }
    }

    /// Records the outcome and resumes every waiter, unless an outcome was already recorded.
    ///
    /// Two things may finish a request — Apple's answer and the asset check — and the first wins.
    ///
    /// - Returns: Whether this call was the one that finished it.
    @discardableResult
    private func finish(with outcome: Result<Outcome, Error>) -> Bool {
        let finished = state.withLock { state -> ([UUID: Waiter], Task<Void, Never>?)? in
            guard state.outcome == nil else {
                return nil
            }
            state.outcome = outcome
            let waiters = state.waiters
            let checkTask = state.checkTask
            state.waiters = [:]
            state.checkTask = nil
            return (waiters, checkTask)
        }
        guard let (waiters, checkTask) = finished else {
            return false
        }

        // Unregistered before any waiter resumes, so a caller arriving from here on starts a fresh
        // request — after `.notAvailable` or `.error`, asking again is the only way to find out if
        // that changed. Only if still registered: a superseded request must not remove its
        // replacement.
        Self.inFlight.withLock { requests in
            if requests[key] === self {
                requests[key] = nil
            }
        }
        checkTask?.cancel()
        for waiter in waiters.values {
            waiter.timer?.cancel()
            waiter.continuation.resume(with: outcome.map { $0 })
        }
        return true
    }

    /// Resumes one waiter, if it is still waiting. Whichever of the request, the asset check, the
    /// timer and the cancellation handler gets here first wins; the others find nothing to resume.
    private func resume(_ waiterID: UUID, with result: Result<Outcome?, Error>) {
        // Resumed outside the lock, the rule `RTSRAGRateGovernor` follows: a continuation runs
        // its caller's code, and none of that belongs under a non-reentrant lock.
        let (waiter, idleCheckTask) = state.withLock { state in
            let waiter = state.waiters.removeValue(forKey: waiterID)
            guard state.waiters.isEmpty else {
                return (waiter, nil as Task<Void, Never>?)
            }
            // The last waiter left: nobody needs the check any more.
            let checkTask = state.checkTask
            state.checkTask = nil
            return (waiter, checkTask)
        }
        idleCheckTask?.cancel()
        waiter?.timer?.cancel()
        waiter?.continuation.resume(with: result)
    }
}
