//
//  RTSConcurrencyLimiter.swift
//  RailtracksSwift
//

import Foundation

/// An `actor` counting semaphore bounding the number of concurrently in-flight `await`-suspended
/// operations (e.g. LLM network calls). Swift's cooperative thread pool bounds CPU work, not tasks
/// parked in `await`, so a fan-out of network calls needs an explicit cap. A `nil` limit means
/// unbounded (used for on-device providers, whose ceiling is the device, not an account quota).
///
/// Scope is **per-provider and process-wide**: the real constraint is the provider's account-level
/// rate limit, shared across every `evaluate()` run in the process. Resolve the shared instance for
/// a provider via `RTSConcurrencyLimiter.shared(for:)`; construct a private one only for tests.
public actor RTSConcurrencyLimiter {
    private let limit: Int?
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter limit: max concurrent permits; `nil` means unbounded. Values below 1 clamp to 1.
    public init(limit: Int?) {
        self.limit = limit.map { Swift.max(1, $0) }
    }

    /// Run `operation` while holding one permit, releasing it (even on throw) when it completes.
    /// `nonisolated` so `operation` runs on its own executor rather than serialized on this actor;
    /// only the permit bookkeeping hops onto the actor.
    public nonisolated func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        // Fast-fail already-cancelled work before taking a permit. A task already parked in `waiters`
        // unwinds only once a permit frees (it still drains — `withPermit` always releases in its
        // catch). Promptly waking a parked waiter on cancel is intentionally not handled: it only
        // matters when cancelling a live evaluation mid-flight, which isn't a scenario here.
        try Task.checkCancellation()
        await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard let limit else {
            // unbounded — never waits
            return
        }
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard limit != nil else {
            return
        }
        if waiters.isEmpty {
            inUse -= 1
        } else {
            let next = waiters.removeFirst()
            // hand the permit to the next waiter; inUse unchanged
            next.resume()
        }
    }
}

// MARK: - Per-provider limits configuration

/// Declares the concurrency cap for each LLM provider kind. Remote providers get a finite cap (their
/// account rate limit); on-device providers are `unbounded`. Kinds in neither collection use `fallback`.
public struct RTSConcurrencyLimits: Sendable {
    public var perProvider: [RTSLLMProviderKind: Int]
    public var unbounded: Set<RTSLLMProviderKind>
    public var fallback: Int

    public init(
        perProvider: [RTSLLMProviderKind: Int],
        unbounded: Set<RTSLLMProviderKind>,
        fallback: Int
    ) {
        self.perProvider = perProvider
        self.unbounded = unbounded
        self.fallback = fallback
    }

    /// The cap for a provider kind, or `nil` if it is unbounded.
    public func limit(for kind: RTSLLMProviderKind) -> Int? {
        if unbounded.contains(kind) {
            return nil
        }
        return perProvider[kind] ?? fallback
    }

    /// Default: OpenAI capped at 15 concurrent calls; Apple on-device capped at **1**; others 15.
    /// On-device FoundationModels does not truly parallelize — it serializes inference on the ANE/GPU,
    /// so concurrent calls only queue and contend. Confirmed empirically (unbounded / 5 / 2 caps were
    /// all as slow or slower than 1) and by external docs on on-device inference being effectively
    /// serial. So `.appleAI: 1` is the correct value, not merely a safety default. (OpenAI's 15 is real
    /// parallelism — independent remote workers.)
    ///
    /// Exposed to the app via `RTSEvaluation.evaluate(..., limits:)` (and directly via `configure(_:)`),
    /// so an app can tune per-provider caps (e.g. `.openAI: 13`).
    /// TODO: two remaining gaps — (1) `RTSLLMProviderKind` only has `.openAI`/`.appleAI`, so caps for
    /// Anthropic/Gemini/etc. can't be set until those cases exist; (2) `configure` is "first-created
    /// wins" (see `LLMProviderRegistry`), so it can't retune a limiter already created this process —
    /// reconfiguration mid-process would need the registry to replace live limiters.
    public static let `default` = RTSConcurrencyLimits(
        perProvider: [.openAI: 15, .appleAI: 1],
        unbounded: [],
        fallback: 15
    )
}

// MARK: - Process-wide per-provider registry

public extension RTSConcurrencyLimiter {
    /// The shared limiter for a provider kind, created on first request from the configured limits and
    /// reused thereafter — so two concurrent `evaluate()` runs on the same provider share one cap.
    static func shared(for kind: RTSLLMProviderKind) async -> RTSConcurrencyLimiter {
        await registry.limiter(for: kind)
    }

    /// Override the limits used for **not-yet-created** shared limiters. Already-created limiters keep
    /// their cap (they may already be in use), so configure before the first `evaluate()` of a process.
    static func configure(_ limits: RTSConcurrencyLimits) async {
        await registry.configure(limits)
    }

    private static let registry = LLMProviderRegistry()

    private actor LLMProviderRegistry {
        private var limits: RTSConcurrencyLimits = .default
        private var limiters: [RTSLLMProviderKind: RTSConcurrencyLimiter] = [:]

        func configure(_ newLimits: RTSConcurrencyLimits) {
            limits = newLimits
        }

        func limiter(for kind: RTSLLMProviderKind) -> RTSConcurrencyLimiter {
            if let existing = limiters[kind] {
                return existing
            }
            let limiter = RTSConcurrencyLimiter(limit: limits.limit(for: kind))
            limiters[kind] = limiter
            return limiter
        }
    }
}
