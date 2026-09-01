//
//  ErrorReportingTests.swift
//  RailtracksSwiftTests
//

import Testing
import Foundation
@testable import RailtracksSwift

/// Minimal orchestrator whose body is supplied as a closure.
private struct StubOrchestrator: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName: String
    let body: @Sendable (RTSInput, RTSRunContext) async throws -> RTSOutput

    func name() -> String { nodeName }
    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        try await body(input, context)
    }
}

// Serialized: these tests run a full `RTSFlow`, which touches process-global state
// (`flowGraphOutputDirectory`, the shared Instruments signpost API).
extension RailtracksSwiftTestSuite {
    @Suite("Error Reporting", .serialized)
    struct ErrorReportingTests {

        /// The RailtownLogger hook in `flow.run`'s catch block must not swallow, wrap,
        /// or delay the error. With the logger unconfigured (the default here), reporting
        /// is a no-op and the identical error — case and associated value — rethrows.
        @Test("flow errors rethrow unchanged with RailtownLogger unconfigured")
        func flowErrorRethrowsUnchanged() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let root = StubOrchestrator(nodeName: "Boom") { _, _ in
                throw RTSError.missingInput("intentional test failure")
            }
            let flow = RTSFlow(title: "ErrorReportingTest")

            var thrown: Error?
            do {
                _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            } catch {
                thrown = error
            }

            guard case .missingInput(let detail)? = thrown as? RTSError else {
                Issue.record("Expected RTSError.missingInput, got \(String(describing: thrown))")
                return
            }
            #expect(detail == "intentional test failure")
        }

        /// Session-build failures (e.g. no API key) throw before any node runs and are
        /// reported on their own path in `run(agent:...)`; that hook must also rethrow
        /// the identical error.
        @Test("agent session failures rethrow unchanged with RailtownLogger unconfigured")
        func agentSessionFailureRethrowsUnchanged() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let agent = RTSAgent(llmProvider: .anthropic(modelIDString: "claude-test"))
            let flow = RTSFlow(title: "ErrorReportingSessionTest")

            var thrown: Error?
            do {
                _ = try await flow.run(agent: agent, prompt: "hi", gateway: RTSLLMGateway(apiKeys: [:]))
            } catch {
                thrown = error
            }

            guard case .missingAPIKey? = thrown as? RTSError else {
                Issue.record("Expected RTSError.missingAPIKey, got \(String(describing: thrown))")
                return
            }
        }
    }
}
