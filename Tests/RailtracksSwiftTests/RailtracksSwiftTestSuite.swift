//
//  RailtracksSwiftTestSuite.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-08-13.
//

import Testing

/// Root suite for the whole test target: every suite in this target is nested into it from its own
/// file via `extension RailtracksSwiftTestSuite { ... }`, so `.serialized` here applies to all of them.
///
/// Why the target must be serialized: the library exposes process-global configuration —
/// `RailtracksSwift.flowGraphOutputDirectory` and `evaluationOutputDirectory` are
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
@Suite("RailtracksSwift", .serialized)
struct RailtracksSwiftTestSuite {
}
