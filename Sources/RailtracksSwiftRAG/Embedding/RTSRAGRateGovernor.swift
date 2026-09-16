//
//  RTSRAGRateGovernor.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation

/// An adaptive concurrency limiter that converges on the rate a provider actually accepts.
///
/// **Provider-agnostic on purpose.** It knows nothing about HTTP, status codes or error bodies —
/// an embedder *tells* it what happened. That is the same split as ``RTSRAGSplitter`` and
/// ``RTSRAGChunker``, and for the same reason: the feedback loop is the fiddly half and deciding
/// *which response means back off* is a few provider-specific lines. A custom Cohere, Voyage or
/// Azure embedder reuses this and writes only its classifier.
///
/// The loop is AIMD — additive increase, multiplicative decrease — the same shape as TCP
/// congestion control, so the permit count settles near what the provider tolerates rather than
/// being guessed up front.
///
/// ```swift
/// let governor = RTSRAGRateGovernor(initialLimit: 4, maximumLimit: 32)
/// let response = try await governor.withSlot {
///     try await send(request)
/// }
/// ```
///
/// - Note: ``RTSRAGAppleEmbedding`` composes none of this. On-device embedding has no quota and no
///   429; its constraint is a non-`Sendable` model that must not be used concurrently, which actor
///   isolation solves and a rate limiter does not.
public actor RTSRAGRateGovernor {

    /// How many requests may be in flight right now.
    private var limit: Int
    private let minimumLimit: Int
    private let maximumLimit: Int
    private var inFlight = 0
    /// Successes since the last increase. Increasing every N successes rather than every success
    /// keeps the climb gentle enough that it does not immediately re-trip the limit it just found.
    private var successesSinceIncrease = 0
    private let successesPerIncrease: Int
    /// Set once the provider says the account is out of credit. The limit then never climbs again
    /// for this governor's lifetime — probing upward cannot help and only wastes requests.
    private var isCapped = false
    /// Earliest time a new slot may start, honouring a provider's `Retry-After`.
    private var openAt = Date.distantPast
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        initialLimit: Int = 4,
        minimumLimit: Int = 1,
        maximumLimit: Int = 32,
        successesPerIncrease: Int = 8
    ) {
        self.limit = max(minimumLimit, min(initialLimit, maximumLimit))
        self.minimumLimit = max(1, minimumLimit)
        self.maximumLimit = max(self.minimumLimit, maximumLimit)
        self.successesPerIncrease = max(1, successesPerIncrease)
    }

    /// The current permit count. Exposed for reporting and tests.
    public var currentLimit: Int {
        limit
    }

    /// Runs `work` once a slot is free and any back-off window has elapsed.
    ///
    /// Releases the slot however `work` ends, including cancellation — a leaked permit would
    /// shrink throughput permanently with nothing to indicate why.
    public func withSlot<T>(_ work: () async throws -> T) async rethrows -> T {
        await acquire()
        defer {
            release()
        }
        return try await work()
    }

    /// The call succeeded.
    ///
    /// - Parameter headroom: the fraction of the provider's budget still unspent, `0...1`, when the
    ///   provider reports it. `nil` — the default — falls back to pure AIMD, which discovers the
    ///   limit by crossing it.
    ///
    ///   **Supplying it converts the loop from reactive to informed**, and the difference is worth
    ///   stating: without it the limit climbs until a request is refused, halves, and climbs again,
    ///   so steady state is a sawtooth that costs one 429 per cycle. With it the governor sees the
    ///   budget thinning and stops climbing *before* being refused, settling into a plateau just
    ///   under the real limit with no 429s at all.
    ///
    ///   Kept optional because it is not universally available: OpenAI sends
    ///   `x-ratelimit-remaining-*` on every response, but a compatible gateway or a self-hosted
    ///   endpoint may send nothing, and the AIMD fallback has to still work there.
    public func recordSuccess(headroom: Double? = nil) {
        guard !isCapped else {
            return
        }
        if let headroom {
            // Below the floor the budget is nearly spent, so ease off now rather than wait to be
            // refused. A gentle decrement, not the halving `recordBackoff` uses — nothing has gone
            // wrong yet, and overreacting to a dip would give up throughput the account is still
            // entitled to.
            guard headroom > RTSRAGRateGovernor.headroomFloor else {
                successesSinceIncrease = 0
                limit = max(minimumLimit, limit - 1)
                return
            }
            // Comfortable but not ample: hold. Climbing here is what would trip the limit.
            guard headroom > RTSRAGRateGovernor.headroomCeiling else {
                successesSinceIncrease = 0
                return
            }
        }
        successesSinceIncrease += 1
        guard successesSinceIncrease >= successesPerIncrease else {
            return
        }
        successesSinceIncrease = 0
        limit = min(limit + 1, maximumLimit)
        resumeWaiters()
    }

    /// Below this fraction of budget remaining, shed a permit rather than wait to be refused.
    private static let headroomFloor = 0.1
    /// Above this fraction, the budget is ample enough that climbing is safe.
    private static let headroomCeiling = 0.5

    /// The provider asked for less: halve the limit, and hold new slots until `retryAfter` passes.
    ///
    /// Multiplicative decrease rather than a decrement because backing off slowly means spending
    /// the interval still being refused — the point is to get under the limit quickly and re-climb.
    public func recordBackoff(retryAfter: TimeInterval? = nil) {
        successesSinceIncrease = 0
        limit = max(minimumLimit, limit / 2)
        if let retryAfter, retryAfter > 0 {
            openAt = max(openAt, Date().addingTimeInterval(retryAfter))
        }
    }

    /// The account cannot serve more requests at any rate — out of credit.
    ///
    /// Distinct from ``recordBackoff(retryAfter:)`` because it shares a status code with it and
    /// means the opposite: no amount of tuning helps, so the limit is pinned at its floor and never
    /// climbs again.
    public func recordFatal() {
        isCapped = true
        limit = minimumLimit
        successesSinceIncrease = 0
    }

    // MARK: - Permits

    private func acquire() async {
        while true {
            let wait = openAt.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            if inFlight < limit {
                inFlight += 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private func release() {
        inFlight = max(0, inFlight - 1)
        resumeWaiters()
    }

    /// Wakes as many waiters as there are free slots. Woken waiters re-check rather than assume a
    /// slot is theirs, so a limit that shrank between wake and resume is still respected.
    private func resumeWaiters() {
        while inFlight < limit, !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}
