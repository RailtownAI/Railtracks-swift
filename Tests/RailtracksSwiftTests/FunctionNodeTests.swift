//
//  FunctionNodeTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-06-30.
//

import Testing
import Foundation
@testable import RailtracksSwift

private func str(_ v: RTSValue?) -> String? {
    if case let .string(s)? = v { return s }
    return nil
}

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
// (`flowGraphOutputDirectory`, the shared Instruments signpost API), so they must not
// run concurrently with each other.
@Suite("Function Node", .serialized)
struct FunctionNodeTests {

    /// A function node as the flow entry point returns its output (no agents involved).
    @Test("orchestrator as flow root returns its output")
    func functionRoot() async throws {
        RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

        let root = StubOrchestrator(nodeName: "Root") { input, _ in
            ["result": .string("done:\(str(input["x"]) ?? "")")]
        }
        let flow = RTSFlow(title: "FnRootTest")
        let out = try await flow.run(root, input: ["x": .string("hi")], gateway: RTSLLMGateway(apiKeys: [:]))

        #expect(str(out["result"]) == "done:hi")
    }

    /// A function node calling another function node composes, with output propagating.
    @Test("function → function composes")
    func functionToFunction() async throws {
        RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

        let inner = StubOrchestrator(nodeName: "Inner") { _, _ in
            ["result": .string("inner")]
        }
        let outer = StubOrchestrator(nodeName: "Outer") { _, context in
            let childOutput = try await context.call(inner, input: [:])
            return ["result": .string("outer+" + (str(childOutput["result"]) ?? ""))]
        }
        let flow = RTSFlow(title: "FnToFnTest")
        let out = try await flow.run(outer, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

        #expect(str(out["result"]) == "outer+inner")
    }
}
