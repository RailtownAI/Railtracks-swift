//
//  RailtracksSwiftTestSuite.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-08-13.
//

import Foundation
import Testing
@testable import RailtracksSwift

/// Redirects `RailtracksSwift.eventsOutputDirectory` into the temporary directory before every
/// test in the target.
///
/// `RTSFlow` builds its own `RTSEventWriter` whenever it saves a trace, and that writer resolves
/// the global when nothing overrides it — which defaults to the developer's `~/Documents/events`.
/// Without this, an ordinary `swift test` would drop a JSONL file there for every flow the suite
/// constructs. `isRecursive` is what carries it into the nested suites, since every suite in this
/// target hangs off the root below.
///
/// - Note: tests clean up by deleting a uniquely-named directory they created themselves. Nothing
///   should ever `removeItem` this path: if the redirect were to stop applying, that would delete
///   a real user folder.
struct RedirectsEventOutput: SuiteTrait, TestTrait {
    var isRecursive: Bool {
        true
    }

    /// Where the suite's event logs go. Named once so a test can assert the redirect applied.
    static let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("rts-test-events", isDirectory: true)

    func prepare(for test: Test) async throws {
        RailtracksSwift.eventsOutputDirectory = RedirectsEventOutput.directory
    }
}

extension Trait where Self == RedirectsEventOutput {
    static var redirectsEventOutput: Self {
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
@Suite("RailtracksSwift", .serialized, .redirectsEventOutput)
struct RailtracksSwiftTestSuite {
}
