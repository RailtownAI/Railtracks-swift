//
//  ErrorReportingTests.swift
//  RailtracksSwiftTests
//

import Testing
import Foundation
import RailtownLogger
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

            guard case .missingInput(let detail, _)? = thrown as? RTSError else {
                Issue.record("Expected RTSError.missingInput, got \(String(describing: thrown))")
                return
            }
            #expect(detail == "intentional test failure")
        }

        /// End to end through the public API: a flow throws an `RTSError`, and the
        /// payload RailtownLogger would upload carries the *raise* site — the line
        /// inside this test, not `RTSFlow`'s catch block.
        ///
        /// Uses the SDK's `entryMirrorDirectory` debug option, which writes each staged
        /// entry to disk in exactly the shape that goes on the wire, so no network and no
        /// real key are needed. Configuring the logger is process-global and there is no
        /// public reset; the other tests here only assert the rethrow, which holds either way.
        @Test("a flow error's raise site reaches the upload payload")
        func raiseSiteReachesTheUploadPayload() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory
            let mirror = FileManager.default.temporaryDirectory
                .appendingPathComponent("railtown-mirror-\(UUID().uuidString)", isDirectory: true)

            // Syntactically valid key; the host is a reserved name that never resolves.
            let key = Data(#"{"u":"example.invalid","o":"o","p":"p","h":"h==","e":"e"}"#.utf8)
                .base64EncodedString()
            try RailtownLogger.configure(
                apiKey: key,
                options: RailtownOptions(
                    flushInterval: 3600,            // never upload during the test
                    observesAppLifecycle: false,
                    entryMirrorDirectory: mirror
                )
            )

            let throwLine = #line + 2
            let root = StubOrchestrator(nodeName: "Boom") { _, _ in
                throw RTSError.missingInput("intentional test failure")
            }
            _ = try? await RTSFlow(title: "CallSiteFlow")
                .run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            // The mirror write is fire-and-forget on a detached task.
            let deadline = Date().addingTimeInterval(3)
            var payload: String?
            while payload == nil, Date() < deadline {
                if let file = try? FileManager.default.contentsOfDirectory(at: mirror, includingPropertiesForKeys: nil).first {
                    payload = try? String(contentsOf: file, encoding: .utf8)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let text = try #require(payload, "no mirrored entry was written")

            #expect(text.contains("FlowTitle: CallSiteFlow"))
            #expect(text.contains("SourceFile: RailtracksSwiftTests/ErrorReportingTests.swift"))
            #expect(text.contains("SourceFunction: raiseSiteReachesTheUploadPayload()"))
            #expect(text.contains("SourceLine: \(throwLine)"))
            #expect(!text.contains("RTSFlow.swift"), "must not point at the reporting code")
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
