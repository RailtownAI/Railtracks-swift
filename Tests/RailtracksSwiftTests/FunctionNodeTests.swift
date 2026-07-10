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

    /// A failed run still produces its JSON trace. `run` must await the collector even when
    /// the root invocation throws — otherwise the run's locals (collector + subscriptions)
    /// are torn down before the file is written, breaking the "trace-ready-on-return"
    /// guarantee for errored runs. Uses an orchestrator that throws, so no LLM is needed.
    @Test("failed run still writes the JSON trace")
    func failedRunWritesTrace() async throws {
        struct StubError: Error {}

        // Dedicated output dir so we only see this run's file (other tests write to temp root).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rts-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        RailtracksSwift.flowGraphOutputDirectory = dir

        let root = StubOrchestrator(nodeName: "Boom") { _, _ in
            throw StubError()
        }
        let flow = RTSFlow(title: "FnErrorTest")

        var thrown: Error?
        do {
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
        } catch {
            thrown = error
        }

        // The error still propagates to the caller...
        #expect(thrown is StubError)

        // ...and the trace was written before `run` returned.
        let jsonFiles = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(!jsonFiles.isEmpty, "a failed run must still write its JSON trace")
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

    /// `RTSOrchestratorTool` exposes the wrapped orchestrator's metadata as a tool and
    /// rejects the plain `RTSToolNode` invocation path (it must go through a bridge).
    @Test("orchestrator tool exposes metadata and rejects direct invocation")
    func orchestratorToolWrapper() async {
        let orchestrator = StubOrchestrator(nodeName: "SubWorkflow") { _, _ in
            ["result": .string("x")]
        }
        let tool = RTSOrchestratorTool(
            orchestrator: orchestrator,
            description: "runs a sub-workflow",
            parameters: RTSToolSchema(parameters: [
                .init(name: "query", description: "the query", type: .string)
            ])
        )

        #expect(tool.toolName == "SubWorkflow")
        #expect(tool.toolDescription == "runs a sub-workflow")
        #expect(tool.parameterSchema.parameters.count == 1)

        await #expect(throws: RTSError.self) {
            _ = try await tool.invoke(runID: UUID())
        }
    }

    /// `.function` serializes as "Tool" (the visualizer only renders Agent/Tool nodes);
    /// Agent/Tool encode unchanged.
    @Test("function node type serializes as Tool")
    func functionNodeTypeEncodesAsTool() throws {
        func encoded(_ t: RTSFlowNodeType) throws -> String? {
            String(data: try JSONEncoder().encode(t), encoding: .utf8)
        }
        #expect(try encoded(.function) == "\"Tool\"")
        #expect(try encoded(.agent) == "\"Agent\"")
        #expect(try encoded(.tool) == "\"Tool\"")
    }
}
