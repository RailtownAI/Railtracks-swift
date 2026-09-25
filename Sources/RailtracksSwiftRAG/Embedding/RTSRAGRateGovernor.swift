//
//  RTSRAGRateGovernor.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation
import Synchronization

/// An adaptive concurrency limiter that converges on the rate a provider actually accepts.
///
/// **Provider-agnostic on purpose.** It knows nothing about HTTP, status codes or error bodies —
/// an embedder *tells* it what happened. That is the same split as ``RTSRAGSplitter`` and
/// ``RTSRAGChunker``, and for the same reason: the feedback loop is the fiddly half and deciding
/// *which response means back off* is a few provider-specific lines. A custom Cohere, Voyage or
/// Azure embedder reuses this and writes only its classifier.
///
/// That describes the **type**, not an instance. One governor must never span two providers — see
/// the scope rule below — and nothing here can catch it if it does, because
/// ``recordSuccess(headroom:)`` takes a bare `Double` and cannot know which budget produced it.
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
/// ## One governor per (key, model), which is the unit a provider meters
///
/// Two embedders drawing on **one budget** must share one governor, or each probes upward on its
/// own 429s and together they exceed a budget neither can observe. ``RTSRAGRateGovernorManager``
/// applies that rule so a caller does not have to:
///
/// ```swift
/// let governors = RTSRAGRateGovernorManager()
/// let full = RTSRAGOpenAIEmbedding(apiKey: key, governors: governors)
/// let narrow = RTSRAGOpenAIEmbedding(apiKey: key, dimensions: 256, governors: governors)
/// ```
///
/// Those two produce vectors for different spaces — `dimensions` is part of
/// ``RTSRAGEmbedding/modelIdentifier`` — so they belong in different stores while competing for one
/// quota, and they get one governor. A different `model` or `apiKey` gets its own.
///
/// The governor is also injectable directly, for scoping one by hand.
///
/// **The pair is the scope, not the key, and never two providers.** OpenAI meters per API key *per
/// model*, and `x-ratelimit-remaining-tokens` reports that model's budget — so a governor shared
/// across `text-embedding-3-small` and `-large` would halve one model's concurrency on the other's
/// 429 and steer its AIMD loop on headroom belonging to something else. Across two *providers* the
/// same three things go wrong and none of them are visible: the permit pool is shared, so an idle
/// provider's requests queue behind a busy one's; and since ``recordSuccess(headroom:)`` takes a
/// plain fraction, one provider's remaining budget is silently applied as the other's. It compiles,
/// runs, and converges on a rate that is correct for neither.
///
/// - Note: ``RTSRAGAppleEmbedding`` composes none of this. On-device embedding has no quota and no
///   429; its constraint is a non-`Sendable` model that must not be used concurrently, which actor
///   isolation solves and a rate limiter does not.
public actor RTSRAGRateGovernor {
    
    /// Below this fraction of budget remaining, shed a permit rather than wait to be refused.
    private static let headroomFloor = 0.1
    /// Above this fraction, the budget is ample enough that climbing is safe.
    private static let headroomCeiling = 0.5

    /// How often thin headroom may step the limit down.
    ///
    /// Matches ``backoffDebounce`` so both pressure responses move at most once a second, which is
    /// roughly one round trip — the rate AIMD is defined at.
    private static let shedDebounce: TimeInterval = 1
    
    /// How long a back-off pauses new starts when the provider names no `Retry-After`.
    private static let defaultBackoffHold: TimeInterval = 1

    /// Within this of the last back-off, a refusal is treated as the same congestion event.
    ///
    /// Deliberately *not* the provider's `Retry-After`: this is about our own in-flight burst, all
    /// of which is about to be refused too, and a provider asking for a 50ms pause has said nothing
    /// about how many of our requests were already in the air.
    private static let backoffDebounce: TimeInterval = 1

    /// How many requests may be in flight right now.
    private var limit: Int
    private let minimumLimit: Int
    private let maximumLimit: Int
    private var inFlight = 0
    /// Successes since the last increase. Increasing every N successes rather than every success
    /// keeps the climb gentle enough that it does not immediately re-trip the limit it just found.
    private var successesSinceIncrease = 0
    private let successesPerIncrease: Int
    /// Earliest time a new slot may start, honouring a provider's `Retry-After`.
    private var openAt = Date.distantPast
    /// When the current congestion event began.
    ///
    /// Separate from ``openAt`` because the two answer different questions and want different
    /// minimums: how long to pause is the *provider's* call and may legitimately be very short,
    /// while what counts as one event is about *our own* burst of in-flight requests. They coincide
    /// for a typical `Retry-After: 2`, which is what made merging them look right.
    private var lastBackoffAt = Date.distantPast
    /// When the limit was last stepped down for thin headroom.
    ///
    /// Its own field rather than sharing ``lastBackoffAt``, because the three pressure responses —
    /// shed, halve, pin — have different strengths and **a weaker one must not suppress a stronger
    /// one**. Sharing would let a shed swallow a genuine 429's halving, which is backwards: the 429
    /// is the better evidence.
    private var lastShedAt = Date.distantPast
    /// Queued acquirers, each wrapped so that a free slot and a cancellation cannot both resume it.
    private var waiters: [CancellationToken] = []
    
    /// The current permit count. Exposed for reporting and tests.
    public var currentLimit: Int {
        limit
    }

    public init(
        initialLimit: Int = 4,
        minimumLimit: Int = 1,
        maximumLimit: Int = 32,
        successesPerIncrease: Int = 8
    ) {
        // Bounds first, then the limit clamped against the *stored* ones. Computing `limit` from
        // the raw arguments let `minimumLimit: 0, initialLimit: 0` store a limit of zero while the
        // floor became one — and `inFlight < 0` is false forever, so nothing could ever acquire and
        // nothing could raise the limit either, since only a completed request does that. A silent,
        // permanent hang from an initialiser that accepted the argument without complaint.
        self.minimumLimit = max(1, minimumLimit)
        self.maximumLimit = max(self.minimumLimit, maximumLimit)
        self.limit = max(self.minimumLimit, min(initialLimit, self.maximumLimit))
        self.successesPerIncrease = max(1, successesPerIncrease)
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
        if let headroom {
            // Below the floor the budget is nearly spent, so ease off now rather than wait to be
            // refused. A gentle decrement, not the halving `recordBackoff` uses — nothing has gone
            // wrong yet, and overreacting to a dip would give up throughput the account is still
            // entitled to.
            //
            // Debounced for the same reason the halving is, and the case is *more* common: thin
            // headroom is not an event but a **condition** that persists for the rest of the rate
            // window. Stepping down per success would take 32 in-flight successes to the floor,
            // and since a per-minute budget runs thin at the tail of every window, that collapse
            // would repeat every minute with a climb of one per eight successes to recover.
            //
            // `successesSinceIncrease` is still reset on every low-headroom success even when the
            // step is suppressed — thin budget should stop the climb *continuously*, while only
            // moving the limit down *periodically*.
            guard headroom > RTSRAGRateGovernor.headroomFloor else {
                successesSinceIncrease = 0
                let now = Date()
                if now.timeIntervalSince(lastShedAt) >= RTSRAGRateGovernor.shedDebounce {
                    lastShedAt = now
                    limit = max(minimumLimit, limit - 1)
                }
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

    /// The provider asked for less: halve the limit, and hold new slots until `retryAfter` passes.
    ///
    /// Multiplicative decrease rather than a decrement because backing off slowly means spending
    /// the interval still being refused — the point is to get under the limit quickly and re-climb.
    public func recordBackoff(retryAfter: TimeInterval? = nil) {
        // **Halve once per congestion event, not once per refusal.** Every request already in
        // flight when the limit dropped is about to be refused too, and those refusals are the same
        // event rather than new information: with 32 in flight and all refused, halving per failure
        // walks 32 → 16 → 8 → … → 1 from a single round trip, undoing the calibration this exists
        // to hold. AIMD halves once per round trip.
        //
        // Measured against ``lastBackoffAt`` rather than ``openAt``. An earlier version used the
        // hold window for both, which coincides for a typical `Retry-After: 2` and breaks at the
        // degenerate values: `Retry-After: 0` — or a negative one, which `TimeInterval.init` parses
        // happily from `"-5"` — puts `openAt` at or before now, so the very next refusal passes this
        // guard and the collapse returns in full.
        let now = Date()
        guard now.timeIntervalSince(lastBackoffAt) >= RTSRAGRateGovernor.backoffDebounce else {
            return
        }
        lastBackoffAt = now
        successesSinceIncrease = 0
        limit = max(minimumLimit, limit / 2)
        // A hold is imposed even without `Retry-After`, where previously there was none. Firing
        // straight back into a limit that just refused you is what produces the burst in the first
        // place.
        //
        // The provider's own figure wins when it sends one, including when it is *shorter* than the
        // default: it knows its limits and we do not, and overriding a deliberate 200ms with a
        // blanket second would hold back throughput the account is entitled to. Clamped at zero so
        // a malformed or negative header cannot push the window into the past.
        openAt = now.addingTimeInterval(max(0, retryAfter ?? RTSRAGRateGovernor.defaultBackoffHold))
    }

    /// The account cannot serve more requests at any rate — out of credit.
    ///
    /// Drops straight to the floor rather than halving, and imposes no hold: unlike a rate limit,
    /// there is no rate low enough to succeed, so there is nothing to converge on and nothing to
    /// wait out. The two share a status code and mean opposite things.
    ///
    /// - Note: **this cannot help the run that reports it.** `quotaExhausted` is classified
    ///   `endsTheRun`, so the caller throws and stops as soon as it sees one — the limit never gets
    ///   used again in that run. What it is for is a governor *shared across runs*, the pattern this
    ///   type's documentation encourages: the next run then starts at the floor instead of
    ///   optimistically at `initialLimit`.
    ///
    ///   The floor is not a latch. Nothing prevents a later success from climbing back, which is
    ///   correct — a success is direct evidence the account is funded again, and an earlier version
    ///   that *did* latch left a shared governor pinned forever after one exhausted run, with no way
    ///   back short of constructing a new one.
    public func recordFatal() {
        limit = minimumLimit
        successesSinceIncrease = 0
    }

    // MARK: - Permits

    /// Takes a permit, waiting for a free slot and for any back-off window to elapse.
    ///
    /// **Cancellation ends the wait rather than being swallowed**, and both halves of that matter:
    ///
    /// - A cancelled `Task.sleep` throws *immediately*. An earlier version wrote
    ///   `try? await Task.sleep(…)` and then `continue`, which recomputed the same positive wait
    ///   and slept again — a hot loop burning a core for the whole `Retry-After` window. Measured at
    ///   200,000 iterations in half a second.
    /// - A continuation has no cancellation handling of its own, so a task cancelled while queued
    ///   would never be resumed: `withSlot` would never return and its caller's cleanup would never
    ///   run. Hence ``CancellationToken`` and the handler below.
    ///
    /// A cancelled acquire still takes its permit, so `withSlot`'s `defer` releases exactly one.
    /// The cancellation is then observed by `work` itself, which is where it belongs.
    private func acquire() async {
        while !Task.isCancelled {
            let wait = openAt.timeIntervalSinceNow
            if wait > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } catch {
                    break
                }
                continue
            }
            if inFlight < limit {
                inFlight += 1
                return
            }
            let token = CancellationToken()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    // The handler may already have fired between the `isCancelled` check and here,
                    // in which case resume now rather than joining a queue nothing will drain.
                    if token.claim(continuation) == false {
                        continuation.resume()
                    } else {
                        waiters.append(token)
                    }
                }
            } onCancel: {
                token.cancel()
            }
        }
        // Cancelled: take the permit anyway so the release in `withSlot` stays balanced.
        inFlight += 1
    }

    private func release() {
        inFlight = max(0, inFlight - 1)
        resumeWaiters()
    }

    /// Wakes as many waiters as there are free slots. Woken waiters re-check rather than assume a
    /// slot is theirs, so a limit that shrank between wake and resume is still respected.
    ///
    /// Tokens already cancelled are dropped without counting against the wake budget — they resumed
    /// themselves and are no longer queueing.
    ///
    /// - Note: that is also the *only* place they are reclaimed, so a cancelled waiter's token sits
    ///   in `waiters` until the next drain. Deliberate: removing it at cancellation time would need
    ///   a `Task` hop onto the actor from the `@Sendable` handler, which costs more than the ~60
    ///   bytes it frees, and the entries go anyway the moment any slot frees. Only a governor that
    ///   takes cancellations and then idles forever holds them — and it is about to be deallocated.
    private func resumeWaiters() {
        // Counted locally rather than re-reading `inFlight`, which does not move until each woken
        // task actually takes its permit. Testing `inFlight < limit` in the loop condition is true
        // throughout, so one freed slot would wake *every* waiter and all but one would re-queue —
        // O(N) wakeups and N fresh tokens per slot.
        var available = limit - inFlight
        while available > 0, !waiters.isEmpty {
            // A token that cancellation already resolved is discarded without spending a slot: it
            // resumed itself and is no longer queueing for one.
            if waiters.removeFirst().resumeIfWaiting() {
                available -= 1
            }
        }
    }
}

// MARK: - CancellationToken

/// Holds a queued waiter's continuation so that either the governor or a cancellation can resume
/// it, whichever happens first, and never both.
///
/// A plain `CheckedContinuation` cannot be handed to a cancellation handler safely: the handler runs
/// on an arbitrary thread, outside the actor, so the race between "the governor freed a slot" and
/// "this task was cancelled" needs its own lock. Resuming twice traps; resuming never hangs.
/// `Mutex` rather than a lock held by hand, and rather than a serial `DispatchQueue`: `sync` would
/// block a cooperative-pool thread from inside the cancellation handler, `async` could not return
/// the `Bool` `claim` needs, and a queue per queued acquire is far heavier than this. Every
/// critical section here is a few assignments, which is exactly what a mutex is for.
private final class CancellationToken: Sendable {

    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var isResolved = false
    }

    private let state = Mutex(State())

    /// Stores the continuation, or reports `false` when cancellation already won.
    func claim(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        state.withLock { state in
            guard !state.isResolved else {
                return false
            }
            state.continuation = continuation
            return true
        }
    }

    /// Resumes because a slot is free. `false` when cancellation got there first.
    func resumeIfWaiting() -> Bool {
        // Taken out of the lock before resuming: a resume is cheap but it is still someone else's
        // code, and holding a lock across it is the habit that eventually deadlocks.
        let pending = state.withLock { state -> (CheckedContinuation<Void, Never>?, Bool) in
            let continuation = state.continuation
            let wasResolved = state.isResolved
            state.continuation = nil
            state.isResolved = true
            return (continuation, wasResolved)
        }
        pending.0?.resume()
        return !pending.1
    }

    /// Resumes because the task was cancelled, so `acquire` can re-check and bail out.
    func cancel() {
        let pending = state.withLock { state -> CheckedContinuation<Void, Never>? in
            let continuation = state.continuation
            state.continuation = nil
            state.isResolved = true
            return continuation
        }
        pending?.resume()
    }
}
