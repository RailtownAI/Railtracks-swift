//
//  EvaluationTests.swift
//  RailtracksSwiftTests
//
//  Phase 1 validation: the ISO↔epoch date codec. (The report Codable structs and ingestion are
//  exercised by the self-contained Phase 2/3 evaluator tests, so no external-data tests live here.)
//

import Testing
import Foundation
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {
    @Suite("Evaluation — Phase 1")
    struct EvaluationTests {

        /// The custom ISO↔epoch codec preserves microseconds.
        @Test("ISO date codec round-trips microseconds")
        func isoDateRoundTrips() throws {
            let iso = "2026-06-15T16:35:26.817078Z"
            let epoch = try #require(RTSISODate.parse(iso))
            let back = RTSISODate.format(epoch)
            #expect(back == iso)
            // and via Codable
            let date = RTSISODate(epoch: epoch)
            let encoded = try JSONEncoder().encode([date])
            let decoded = try JSONDecoder().decode([RTSISODate].self, from: encoded)
            #expect(abs(decoded[0].epoch - epoch) < 1e-6)
        }
    }
}
