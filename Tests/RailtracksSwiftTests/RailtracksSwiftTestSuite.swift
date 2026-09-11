//
//  RailtracksSwiftTestSuite.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-08-13.
//

import Foundation
import Testing
@testable import RailtracksSwift

/// Redirects `RailtracksSwift.outputDirectory` into the temporary directory before every test in
/// the target, so nothing the suite writes lands in the developer's `~/Documents`.
///
/// It defaults there, and `RTSFlow` now builds its own `RTSEventWriter` whenever it saves a
/// trace — so without this, an ordinary `swift test` would drop a JSONL file into
/// `~/Documents/events` for every flow the suite constructs, plus traces under `sessions`.
/// Setting the one root covers all three artifacts. `isRecursive` is what carries it into the
/// nested suites, since every suite in this target hangs off the root below.
///
/// - Note: tests clean up by deleting a uniquely-named directory they created themselves. Nothing
///   should ever `removeItem` this path: if the redirect were to stop applying, that would delete
///   a real user folder.
struct RedirectsOutput: SuiteTrait, TestTrait {
    var isRecursive: Bool {
        true
    }

    /// Where the suite writes. Named once so a test can assert the redirect applied.
    static let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rts-test-output", isDirectory: true)

    func prepare(for test: Test) async throws {
        RailtracksSwift.outputDirectory = RedirectsOutput.directory
    }
}

extension Trait where Self == RedirectsOutput {
    static var redirectsOutput: Self {
        Self()
    }
}

/// Root suite for the whole test target: every suite in this target is nested into it from its own
/// file via `extension RailtracksSwiftTestSuite { ... }`, so `.serialized` here applies to all of them.
///
/// Why the target must be serialized: the library exposes process-global configuration —
/// `RailtracksSwift.flowGraphOutputDirectory`, `evaluationOutputDirectory` and
/// `eventsOutputDirectory` are
/// `nonisolated(unsafe) static var`s documented "configure once at app startup" — and several suites
/// reassign them to redirect a flow's trace. `.serialized` on an individual suite only orders the
/// tests *within* that suite; two independent suites still run concurrently (measured), which let one
/// suite's flow write its trace into another suite's output directory moments before that suite's
/// `defer` deleted it. The result was `DuplicateNodeIdTests` failing roughly one run in four with
/// `.writeFileFailed` or a missing file — nothing to do with the behavior under test.
///
/// Serializing is cheap here (the target runs in ~1–2s, dominated by one AppleAI probe) and removes
/// the whole class of cross-suite interference. When adding a suite, nest it into this root the same
/// way; a suite declared at file scope opts itself out and may race with the rest.
@Suite("RailtracksSwift", .serialized, .redirectsOutput)
struct RailtracksSwiftTestSuite {
}
