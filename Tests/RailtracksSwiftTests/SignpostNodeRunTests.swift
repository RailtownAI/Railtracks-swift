//
//  SignpostNodeRunTests.swift
//  RailtracksSwiftTests
//

import Testing
import Foundation
@testable import RailtracksSwift

/// Records the interval calls `RTSNodeInvoker` makes; point events are ignored.
private final class RecordingSignpostEmitter: RTSSignpostEmitting, @unchecked Sendable {
    struct Start: Equatable {
        let nodeID: UUID
        let parentNodeID: UUID?
        let nodeName: String
        let nodeType: RTSFlowNodeType
        let runID: RTSRunID
        let input: RTSInput
    }

    struct End: Equatable {
        let nodeID: UUID
        let nodeType: RTSFlowNodeType
        let runID: RTSRunID
        let failed: Bool
    }

    private let lock = NSLock()
    private var _starts: [Start] = []
    private var _ends: [End] = []

    var starts: [Start] { lock.withLock { _starts } }
    var ends: [End] { lock.withLock { _ends } }

    func start(named name: String) -> Start? {
        starts.first { $0.nodeName == name }
    }

    func emitNodeStart(
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        input: RTSInput,
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    ) {
        let start = Start(
            nodeID: nodeID,
            parentNodeID: parentNodeID,
            nodeName: nodeName,
            nodeType: nodeType,
            runID: runID,
            input: input
        )
        lock.withLock { _starts.append(start) }
    }

    func emitNodeEnd(
        nodeID: UUID,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        output: RTSOutput?,
        error: Error?
    ) {
        let end = End(nodeID: nodeID, nodeType: nodeType, runID: runID, failed: error != nil)
        lock.withLock { _ends.append(end) }
    }

    func emitGraphNode(
        nodeID: String, parentID: String, sessionID: String, runID: String,
        nodeType: RTSFlowNodeType, parentType: RTSFlowNodeType?, error: Bool,
        parentError: Bool, cost: Double, model: String, parentName: String,
        name: String, startTime: TimeInterval
    ) {}

    func emitTreeNode(
        nodeID: String, sessionID: String, runID: String, nodeType: RTSFlowNodeType,
        model: String, provider: String, cost: Double, latency: Double,
        inputTokens: Int, outputTokens: Int, error: Bool, ancestors: [String],
        name: String, startTime: TimeInterval,
        hasInputGuardrail: Bool, hasOutputGuardrail: Bool
    ) {}

    func emitIO(
        nodeID: String, sessionID: String, runID: String, messageID: String,
        source: String, direction: String, role: String, model: String,
        provider: String, cost: Double, latency: Double, inputTokens: Int,
        outputTokens: Int, displayRole: String, toolName: String, content: String,
        startTime: TimeInterval, hasInputGuardrail: Bool, hasOutputGuardrail: Bool
    ) {}
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

/// Tool that returns a fixed output, so no LLM is involved in running it.
private struct StubTool: RTSToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName: String
    let toolDescription = "stub tool"
    let parameterSchema = RTSToolSchema(parameters: [])
    let callableRoutine = RTSClosure { _ in ["result": .string("tool")] }
}

extension RailtracksSwiftTestSuite {
    /// Every node call — not just agents — reaches `emitNodeStart`/`emitNodeEnd`, carrying its
    /// type and the invocation id of its caller, so the Instruments Node Runs lane can nest it.
    @Suite("Signpost Node Runs", .serialized)
    struct SignpostNodeRunTests {

        @Test("function → function reports both starts with type and parent id")
        func functionCallsFunction() async throws {
            let emitter = RecordingSignpostEmitter()
            let inner = StubOrchestrator(nodeName: "Inner") { _, _ in
                ["result": .string("inner")]
            }
            let outer = StubOrchestrator(nodeName: "Outer") { _, context in
                try await context.call(inner, input: [:])
            }
            let flow = RTSFlow(title: "SignpostFnToFn", signpostEmitter: emitter)
            _ = try await flow.run(outer, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            #expect(emitter.starts.count == 2)
            let root = try #require(emitter.start(named: "Outer"))
            let child = try #require(emitter.start(named: "Inner"))
            #expect(root.nodeType == .function)
            #expect(child.nodeType == .function)
            #expect(root.parentNodeID == nil)
            #expect(child.parentNodeID == root.nodeID)
            expectEveryStartEnded(emitter)
        }

        @Test("a tool called from an agent reports the agent as its parent")
        func agentCallsTool() async throws {
            let emitter = RecordingSignpostEmitter()
            let invoker = RTSNodeInvoker(
                stampFactory: RTSStampFactory(),
                sessionID: UUID(),
                signpostEmitter: emitter
            )
            let agent = RTSAgent(llmProvider: .openAI(modelIDString: "gpt-4o"), name: "Agent")
            let tool = StubTool(toolName: "Lookup")
            // Stands in for the LLM: the session's `run` makes one tool call through the
            // invoker, the way the Conduit/AppleAI tool bridges do, then answers.
            let session = RTSLLMSession(
                run: { _, _, _ in
                    _ = try await invoker.invokeTool(tool, input: [:], createdBy: agent)
                    return "done"
                },
                setSystemPrompt: { _, _ in },
                message: { [] },
                messageSubject: BufferedPassthroughSubject<[RTSMessage]>(),
                agentName: "Agent"
            )

            _ = try await invoker.invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: session
            )

            #expect(emitter.starts.count == 2)
            let agentStart = try #require(emitter.start(named: "Agent"))
            let toolStart = try #require(emitter.start(named: "Lookup"))
            #expect(agentStart.nodeType == .agent)
            #expect(toolStart.nodeType == .tool)
            #expect(agentStart.parentNodeID == nil)
            #expect(toolStart.parentNodeID == agentStart.nodeID)
            // The agent's start carries the input it ran with, which the emitter summarizes.
            #expect(agentStart.input == ["prompt": .string("hi")])
            #expect(RTSSignpostEmitter.inputSummary(agentStart.input, nodeType: .agent) == "hi")
            expectEveryStartEnded(emitter)
        }

        private func expectEveryStartEnded(_ emitter: RecordingSignpostEmitter) {
            let starts = emitter.starts
            let ends = emitter.ends
            #expect(ends.count == starts.count)
            for start in starts {
                let end = ends.first { $0.runID == start.runID }
                #expect(end?.nodeID == start.nodeID, "no matching end for \(start.nodeName)")
                #expect(end?.nodeType == start.nodeType)
                #expect(end?.failed == false)
            }
        }
    }
}
