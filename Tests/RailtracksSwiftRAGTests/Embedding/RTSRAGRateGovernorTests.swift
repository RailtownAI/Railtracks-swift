//
//  RTSRAGRateGovernorTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// The governor drives entirely on its own — no embedder, no HTTP, no provider.
///
/// That is the point of having split it out: the AIMD loop is the half with the bugs, and here it
/// can be driven directly through states that would need a flaky live provider to reproduce.
@Suite("RailtracksSwiftRAG rate governor")
struct RTSRAGRateGovernorTests {

    @Test("sustained success raises the limit, gradually")
    func successClimbs() async {
        let governor = RTSRAGRateGovernor(initialLimit: 2, maximumLimit: 8, successesPerIncrease: 3)

        for _ in 0..<2 {
            await governor.recordSuccess()
        }
        let beforeThird = await governor.currentLimit
        await governor.recordSuccess()
        let afterThird = await governor.currentLimit

        // Additive increase, and only every N successes — climbing on every one would re-trip the
        // limit it just discovered.
        #expect(beforeThird == 2)
        #expect(afterThird == 3)
    }

    @Test("ample headroom still climbs, thin headroom holds, near-empty sheds")
    func headroomSteersTheClimb() async {
        func limitAfter(headroom: Double, successes: Int) async -> Int {
            let governor = RTSRAGRateGovernor(initialLimit: 4, maximumLimit: 16, successesPerIncrease: 2)
            for _ in 0..<successes {
                await governor.recordSuccess(headroom: headroom)
            }
            return await governor.currentLimit
        }

        // The point of reading the provider's own budget: without it the limit climbs until a
        // request is refused, so steady state is a sawtooth costing one 429 per cycle. With it the
        // governor stops climbing *before* being refused and settles just under the real limit.
        #expect(await limitAfter(headroom: 0.9, successes: 4) == 6)   // ample → climbs
        #expect(await limitAfter(headroom: 0.3, successes: 4) == 4)   // thinning → holds
        #expect(await limitAfter(headroom: 0.02, successes: 1) == 3)  // nearly spent → sheds
    }

    @Test("shedding on thin headroom is gentler than backing off after a refusal")
    func headroomShedIsGentlerThanBackoff() async {
        let shed = RTSRAGRateGovernor(initialLimit: 8, maximumLimit: 16)
        let refused = RTSRAGRateGovernor(initialLimit: 8, maximumLimit: 16)

        await shed.recordSuccess(headroom: 0.01)
        await refused.recordBackoff()

        // Nothing has gone wrong yet when headroom is merely low, so a decrement is right;
        // halving there would give up throughput the account is still entitled to. A 429 is
        // different — it has already been refused, so getting under the limit fast is the priority.
        #expect(await shed.currentLimit == 7)
        #expect(await refused.currentLimit == 4)
    }

    @Test("no headroom reported falls back to plain AIMD")
    func absentHeadroomFallsBack() async {
        let governor = RTSRAGRateGovernor(initialLimit: 4, maximumLimit: 16, successesPerIncrease: 2)

        // A compatible gateway or self-hosted endpoint may send no rate headers at all, so the
        // probing loop has to still work.
        for _ in 0..<2 {
            await governor.recordSuccess()
        }

        #expect(await governor.currentLimit == 5)
    }

    @Test("the limit never exceeds its ceiling")
    func climbIsBounded() async {
        let governor = RTSRAGRateGovernor(initialLimit: 3, maximumLimit: 4, successesPerIncrease: 1)

        for _ in 0..<20 {
            await governor.recordSuccess()
        }

        #expect(await governor.currentLimit == 4)
    }

    @Test("a back-off halves the limit")
    func backoffHalves() async {
        let governor = RTSRAGRateGovernor(initialLimit: 8, maximumLimit: 16)

        await governor.recordBackoff()

        // Multiplicative decrease: backing off one at a time would spend the interval still being
        // refused. The point is to get under the limit fast, then re-climb.
        #expect(await governor.currentLimit == 4)
    }

    @Test("refusals from the same burst halve only once")
    func backoffIsDebouncedWithinItsWindow() async {
        let governor = RTSRAGRateGovernor(initialLimit: 32, maximumLimit: 32)

        // Every request already in flight when the limit dropped is about to be refused too. Those
        // are the same congestion event, not thirty-two of them — halving per refusal would walk
        // 32 → 1 from a single round trip. AIMD halves once per round trip.
        for _ in 0..<32 {
            await governor.recordBackoff()
        }

        #expect(await governor.currentLimit == 16)
    }

    @Test("a back-off after the window halves again", .timeLimit(.minutes(1)))
    func backoffAfterTheWindowHalvesAgain() async {
        // A short `Retry-After` so the window is known and brief rather than the one-second default.
        let governor = RTSRAGRateGovernor(initialLimit: 8, maximumLimit: 16)

        await governor.recordBackoff(retryAfter: 0.2)
        let once = await governor.currentLimit
        try? await Task.sleep(nanoseconds: 350_000_000)
        await governor.recordBackoff(retryAfter: 0.2)

        // Debouncing must not become deafness: a genuinely separate event still halves.
        #expect(once == 4)
        #expect(await governor.currentLimit == 2)
    }

    @Test("the limit never falls below its floor")
    func backoffIsBounded() async {
        // Already at the floor, so the halving has nowhere to go. Driven with one event rather
        // than a loop, since repeated back-offs inside one window now debounce to a single halving.
        let governor = RTSRAGRateGovernor(initialLimit: 1, minimumLimit: 1)

        await governor.recordBackoff()

        // A floor of zero would deadlock every waiter permanently.
        #expect(await governor.currentLimit == 1)
    }

    @Test("an exhausted account pins the limit and stops it climbing back")
    func fatalStopsTheClimb() async {
        let governor = RTSRAGRateGovernor(initialLimit: 8, maximumLimit: 16, successesPerIncrease: 1)

        await governor.recordFatal()
        let afterFatal = await governor.currentLimit
        for _ in 0..<20 {
            await governor.recordSuccess()
        }

        // `quotaExhausted` shares a status code with rate limiting and means the opposite: no rate
        // is low enough to succeed, so probing upward only wastes requests.
        #expect(afterFatal == 1)
        #expect(await governor.currentLimit == 1)
    }

    @Test("concurrent work never exceeds the limit in flight")
    func slotsAreBounded() async {
        let governor = RTSRAGRateGovernor(initialLimit: 3, maximumLimit: 3, successesPerIncrease: 1000)
        let tracker = ConcurrencyPeak()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await governor.withSlot {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await tracker.leave()
                    }
                }
            }
        }

        #expect(await tracker.peak <= 3)
        #expect(await tracker.peak > 1)
    }

    @Test(
        "cancelling during a back-off hold returns promptly instead of spinning",
        .timeLimit(.minutes(1))
    )
    func cancellationEndsTheBackoffWait() async {
        let governor = RTSRAGRateGovernor(initialLimit: 4)
        // A long hold, as a provider's `Retry-After` would set.
        await governor.recordBackoff(retryAfter: 30)

        let started = Date()
        let task = Task {
            await governor.withSlot {
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await task.value

        // A cancelled `Task.sleep` throws immediately, so `try?` plus `continue` recomputed the
        // same positive wait and slept again — 200,000 iterations in half a second, burning a core
        // for the whole retry window. Returning promptly is the fix; the 30-second hold is what
        // makes the old behaviour visible as a hang here.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test(
        "cancelling while queued for a permit does not strand the task",
        .timeLimit(.minutes(1))
    )
    func cancellationReleasesAQueuedWaiter() async {
        let governor = RTSRAGRateGovernor(initialLimit: 1, maximumLimit: 1)
        let occupied = Occupancy()

        // Fill the single slot and hold it, so the next acquire has to queue.
        let holder = Task {
            await governor.withSlot {
                await occupied.markEntered()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        await occupied.waitUntilEntered()

        let queued = Task {
            await governor.withSlot {
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        queued.cancel()

        // Without a cancellation handler the continuation is never resumed, so this never returns
        // and the caller's cleanup — `isRunning = false` in the demo — never runs either.
        await queued.value
        holder.cancel()
        _ = await holder.value
    }

    @Test("a slot is released even when the work throws")
    func slotsSurviveErrors() async {
        let governor = RTSRAGRateGovernor(initialLimit: 1, maximumLimit: 1)
        struct Boom: Error {
        }

        for _ in 0..<5 {
            _ = try? await governor.withSlot {
                throw Boom()
            }
        }

        // A leaked permit shrinks throughput permanently with nothing to indicate why, so this
        // pins that the release is unconditional. If it were not, this test would hang rather
        // than fail.
        await governor.withSlot {
        }
    }
}

// MARK: - Test doubles

/// Lets a test wait until a held slot is actually occupied, rather than sleeping and hoping.
private actor Occupancy {
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        hasEntered = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }

    func waitUntilEntered() async {
        guard !hasEntered else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor ConcurrencyPeak {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}
