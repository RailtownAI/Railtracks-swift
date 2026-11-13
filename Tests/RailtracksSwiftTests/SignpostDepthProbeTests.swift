//
//  SignpostDepthProbeTests.swift
//  THROWAWAY (#70 step 4 diagnosis, not to be committed).
//

import Foundation
import Synchronization
import Testing
@testable import RailtracksSwift

/// Logs begin/end in call order with the depth the kit's NodeRunIndexer would assign.
private final class DepthRecorder: RTSSignpostEmitting, Sendable {
    private let state = Mutex<(live: [UUID: Int], lines: [String])>(([:], []))

    var lines: [String] { state.withLock { $0.lines } }

    func emitNodeStart(
        nodeID: UUID, parentNodeID: UUID?, nodeName: String, nodeType: RTSFlowNodeType,
        sessionID: UUID, parentName: String, runID: RTSRunID, input: RTSInput,
        instructions: String?, hasInputGuardrail: Bool, hasOutputGuardrail: Bool
    ) {
        state.withLock { state in
            let depth = parentNodeID.flatMap { state.live[$0] }.map { $0 + 1 } ?? 0
            state.live[nodeID] = depth
            state.lines.append("begin \(nodeName) depth=\(depth) parent=\(parentName)")
        }
    }

    func emitNodeEnd(
        nodeID: UUID, nodeName: String, nodeType: RTSFlowNodeType, sessionID: UUID,
        parentName: String, runID: RTSRunID, output: RTSOutput?, error: Error?
    ) {
        state.withLock { state in
            state.live[nodeID] = nil
            state.lines.append("end   \(nodeName)")
        }
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
        name: String, startTime: TimeInterval, hasInputGuardrail: Bool, hasOutputGuardrail: Bool
    ) {}

    func emitIO(
        nodeID: String, sessionID: String, runID: String, messageID: String,
        source: String, direction: String, role: String, model: String,
        provider: String, cost: Double, latency: Double, inputTokens: Int,
        outputTokens: Int, displayRole: String, toolName: String, content: String,
        startTime: TimeInterval, hasInputGuardrail: Bool, hasOutputGuardrail: Bool
    ) {}
}

@Test("depth probe: Math demo shape")
func mathShapeDepths() async throws {
    let tool = ScriptedTool("Multiply") { _ in
        try await Task.sleep(for: .milliseconds(5))
        return ["result": .string("96")]
    }
    func agent(_ name: String) -> RTSAgent {
        RTSAgent(llmProvider: toolCallingProvider, name: name, tools: [tool])
    }
    let agentA = agent("Agent A")
    let agentB = agent("Agent B")
    let agentC = agent("Agent C")
    let script = ScriptedReply(
        toolCalls: [ScriptedToolCall(tool: tool, input: ["query": .string("x")])]
    )
    let workflow = ScriptedOrchestrator(nodeName: "Math Workflow") { _, context in
        async let c = context.call(agentC, prompt: "c")
        let a = try await context.call(agentA, prompt: "a")
        let b = try await context.call(agentB, prompt: "\(a) b")
        return ["result": .string(b + (try await c))]
    }
    let recorder = DepthRecorder()
    let flow = RTSFlow(title: "Depth Probe", signpostEmitter: recorder)
    _ = try await flow.run(
        workflow,
        input: [:],
        makeSession: scriptedSessions(["Agent A": script, "Agent B": script, "Agent C": script])
    )
    print("DEPTH-PROBE\n" + recorder.lines.joined(separator: "\n"))
}
