//
//  OutputDirectoryTests.swift
//  RailtracksSwiftTests
//
//  Regression test for 6029: writing the flow-graph JSON report must create a missing output
//  subdirectory (e.g. "sessions") on demand rather than erroring out.
//

import Testing
import Foundation
@testable import RailtracksSwift

/// Minimal orchestrator whose body is supplied as a closure (no LLM).
private struct StubOrchestrator: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName: String
    let body: @Sendable (RTSInput, RTSRunContext) async throws -> RTSOutput

    func name() -> String {
        nodeName
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        try await body(input, context)
    }
}

// Serialized: runs a full `RTSFlow`, which touches the process-global `flowGraphOutputDirectory`.
extension RailtracksSwiftTestSuite {
    @Suite("Output directory", .serialized)
    struct OutputDirectoryTests {

        /// The exact file this flow wrote, via its `outputFileURLPublisher`. Throws on `.failure`, so a
        /// write error (the pre-fix behavior when the directory is missing) fails the test.
        private func writtenTraceURL(_ flow: RTSFlow) async throws -> URL {
            for await result in flow.outputFileURLPublisher.values {
                switch result {
                case .success(let url):
                    return url
                case .failure(let error):
                    throw error
                }
            }
            struct NoTraceURL: Error {}
            throw NoTraceURL()
        }

        @Test("flow run creates a missing output directory and writes the report")
        func createsMissingOutputDirectory() async throws {
            // A unique, nested path guaranteed not to exist — exercises intermediate-directory creation.
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-test-\(UUID().uuidString)", isDirectory: true)
            let outputDirectory = base.appendingPathComponent("sessions", isDirectory: true)
            #expect(!FileManager.default.fileExists(atPath: outputDirectory.path))
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            RailtracksSwift.flowGraphOutputDirectory = outputDirectory

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                ["result": .string("ok")]
            }
            let flow = RTSFlow(title: "OutputDirCreate")
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            // Before the fix this emitted `.failure(writeFileFailed)`, so `writtenTraceURL` would throw.
            let url = try await writtenTraceURL(flow)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
    }
}
