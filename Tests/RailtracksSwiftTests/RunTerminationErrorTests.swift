//
//  RunTerminationErrorTests.swift
//  RailtracksSwiftTests
//

import Testing
@testable import RailtracksSwift

@Suite struct RunTerminationErrorTests {
    /// The factory records where the run was stopped, like every other `RTSError` factory.
    @Test func theFactoryCapturesTheCallSite() {
        let error = RTSError.runTerminated(reason: .cancelled)   // <- the line under test
        let expectedLine = #line - 1

        #expect(error.context.file == "RailtracksSwiftTests/RunTerminationErrorTests.swift")
        #expect(error.context.function == "theFactoryCapturesTheCallSite()")
        #expect(error.context.line == expectedLine)
    }

    /// The reason survives the round trip through the error, so a caller can tell the three
    /// ways of stopping apart.
    @Test func theReasonCanBeMatched() {
        let error: Error = RTSError.runTerminated(reason: .timeout(after: 30))

        guard case .runTerminated(let reason, _)? = error as? RTSError else {
            Issue.record("expected runTerminated, got \(error)")
            return
        }
        guard case .timeout(let seconds) = reason else {
            Issue.record("expected a timeout reason, got \(reason)")
            return
        }
        #expect(seconds == 30)
    }

    /// The description is what traces and events record, so its format is a contract.
    @Test func theDescriptionNamesTheReason() {
        let cancelled = RTSError.runTerminated(reason: .cancelled)
        let timedOut = RTSError.runTerminated(reason: .timeout(after: 30))

        #expect(cancelled.description == "runTerminated(reason: cancelled)")
        #expect(timedOut.description == "runTerminated(reason: timeout(after: 30.0))")
    }

    /// An end-on-error stop names the failing node and includes its error's own description,
    /// leaving the call-site context out, like every other `RTSError` description.
    @Test func anEndOnErrorDescriptionIncludesTheNodeAndItsError() {
        let underlying = RTSError.missingInput("prompt")
        let reason = RTSRunTerminationReason.endOnError(nodeName: "Search", underlying: underlying)
        let error = RTSError.runTerminated(reason: reason)

        let expected = "runTerminated(reason: endOnError(nodeName: \"Search\", "
            + "underlying: missingInput(\"prompt\")))"
        #expect(error.description == expected)
    }
}
