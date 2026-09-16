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
        let once = await governor.currentLimit
        await governor.recordBackoff()
        let twice = await governor.currentLimit

        // Multiplicative decrease: backing off one at a time would spend the interval still being
        // refused. The point is to get under the limit fast, then re-climb.
        #expect(once == 4)
        #expect(twice == 2)
    }

    @Test("the limit never falls below its floor")
    func backoffIsBounded() async {
        let governor = RTSRAGRateGovernor(initialLimit: 4, minimumLimit: 1)

        for _ in 0..<10 {
            await governor.recordBackoff()
        }

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
