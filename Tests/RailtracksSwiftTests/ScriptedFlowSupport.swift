//
//  ScriptedFlowSupport.swift
//  RailtracksSwiftTests
//
//  Scripted models and closure-backed nodes, so a test can run a real `RTSFlow` with agents and
//  tools and no provider. Used by the trace goldens and the node status sequences.
//

import Foundation
import Synchronization
@testable import RailtracksSwift

// MARK: - Scripted model

/// One tool call a scripted model makes before it replies.
struct ScriptedToolCall: Sendable {
    let tool: any RTSToolNode
    let input: RTSInput
}

/// What a scripted model does in one agent invocation: call its tools in order, then reply.
struct ScriptedReply: Sendable {
    var toolCalls: [ScriptedToolCall] = []
    var reply = "done"
    var providerName: String? = "AppleAI"
    var model: String? = "apple-on-device"
    /// When a tool call throws, wait to be cancelled rather than rethrowing, as a provider does
    /// while the run's stop reaches it. Makes an end-on-error stop deterministic.
    var waitsForStopAfterToolFailure = false
}

/// A session that plays a ``ScriptedReply`` and records the messages a real provider would: the
/// system prompt, the user prompt, an assistant message per tool call with its tool result, and
/// the final reply, each stamped with the invocation's `runID`.
final class ScriptedSession: Sendable {
    private let script: ScriptedReply
    private let invoker: RTSNodeInvoker
    private let agent: any RTSAgentNode
    private let log = Mutex<[RTSMessage]>([])

    private init(
        script: ScriptedReply,
        invoker: RTSNodeInvoker,
        agent: any RTSAgentNode
    ) {
        self.script = script
        self.invoker = invoker
        self.agent = agent
    }

    static func make(
        script: ScriptedReply,
        invoker: RTSNodeInvoker,
        agent: any RTSAgentNode
    ) -> RTSLLMSession {
        let scripted = ScriptedSession(script: script, invoker: invoker, agent: agent)
        return RTSLLMSession(
            run: { prompt, _, runID in
                try await scripted.run(prompt: prompt, runID: runID)
            },
            setSystemPrompt: { systemPrompt, runID in
                scripted.record([scripted.message(.system, systemPrompt, runID: runID)])
            },
            message: {
                scripted.log.withLock { $0 }
            },
            agentName: agent.agentName
        )
    }

    private func run(prompt: String, runID: UUID?) async throws -> String {
        var produced = [message(.user, prompt, runID: runID)]
        // Recorded however the call ends, as `RTSLLMSession` records what accumulated when a send
        // throws.
        defer {
            record(produced)
        }
        for (index, call) in script.toolCalls.enumerated() {
            let callID = "call_\(index)"
            produced.append(assistantToolCall(call, callID: callID, runID: runID))
            let output: RTSOutput
            do {
                output = try await invoker.invokeTool(
                    call.tool,
                    input: call.input,
                    createdBy: agent
                )
            } catch {
                guard script.waitsForStopAfterToolFailure else {
                    throw error
                }
                try await Task.sleep(for: .seconds(30))
                throw error
            }
            produced.append(toolResult(output, call: call, callID: callID, runID: runID))
        }
        produced.append(
            message(.assistant, script.reply, runID: runID, metadata: modelMetadata(toolCalls: nil))
        )
        return script.reply
    }

    private func record(_ messages: [RTSMessage]) {
        log.withLock { $0.append(contentsOf: messages) }
    }

    private func message(
        _ role: RTSMessage.Role,
        _ text: String,
        runID: UUID?,
        metadata: RTSMessageMetadata? = nil
    ) -> RTSMessage {
        RTSMessage(
            id: UUID(),
            role: role,
            content: .text(text),
            timestamp: Date(),
            metadata: metadata,
            runID: runID
        )
    }

    private func assistantToolCall(
        _ call: ScriptedToolCall,
        callID: String,
        runID: UUID?
    ) -> RTSMessage {
        let arguments = RTSGeneratedContent(kind: .structure(call.input.mapValues { value in
            RTSGeneratedContent(kind: .string(value.textForScript))
        }))
        let toolCall = RTSToolCall(id: callID, toolName: call.tool.toolName, arguments: arguments)
        return message(.assistant, "", runID: runID, metadata: modelMetadata(toolCalls: [toolCall]))
    }

    private func toolResult(
        _ output: RTSOutput,
        call: ScriptedToolCall,
        callID: String,
        runID: UUID?
    ) -> RTSMessage {
        let metadata = RTSMessageMetadata(
            tokenCount: nil,
            inputTokenCount: nil,
            generationTime: nil,
            model: nil,
            providerName: nil,
            tokensPerSecond: nil,
            providerExtra: nil,
            custom: ["tool_call_id": callID, "tool_name": call.tool.toolName],
            toolCalls: nil
        )
        let text = output["result"]?.textForScript ?? ""
        return message(.tool, text, runID: runID, metadata: metadata)
    }

    private func modelMetadata(toolCalls: [RTSToolCall]?) -> RTSMessageMetadata {
        RTSMessageMetadata(
            tokenCount: 7,
            inputTokenCount: 11,
            generationTime: 0.5,
            model: script.model,
            providerName: script.providerName,
            tokensPerSecond: nil,
            providerExtra: nil,
            custom: nil,
            toolCalls: toolCalls
        )
    }
}

extension RTSValue {
    /// A string value's text, so scripted messages never depend on dictionary ordering.
    var textForScript: String {
        if case .string(let text) = self {
            return text
        }
        return ""
    }
}

/// Builds every agent's session from `scripts`, keyed by agent name.
func scriptedSessions(_ scripts: [String: ScriptedReply]) -> RTSFlow.SessionFactory {
    { invoker, agent in
        ScriptedSession.make(
            script: scripts[agent.agentName] ?? ScriptedReply(),
            invoker: invoker,
            agent: agent
        )
    }
}

/// The provider scripted agents use: local, so `total_cost` is deterministically `null` with no
/// pricing lookup.
let toolCallingProvider = RTSLLMProvider.appleAI

// MARK: - Nodes

/// A tool whose body is supplied as a closure.
struct ScriptedTool: RTSToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName: String
    let toolDescription = "scripted tool"
    let parameterSchema = RTSToolSchema(parameters: [])
    let callableRoutine: RTSClosure

    init(
        _ toolName: String,
        body: @escaping @Sendable (RTSInput) async throws -> RTSOutput
    ) {
        self.toolName = toolName
        self.callableRoutine = RTSClosure(closure: body)
    }
}

/// An orchestrator whose body is supplied as a closure.
struct ScriptedOrchestrator: RTSOrchestratorNode {
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

/// A tool that echoes its `query` input as its result.
func echoTool(_ name: String) -> ScriptedTool {
    ScriptedTool(name) { input in
        ["result": .string("\(name): \(input["query"]?.textForScript ?? "")")]
    }
}
