//
//  RTSOrchestratorNode.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-30.
//

import Foundation

/// A node that runs deterministic Swift code which orchestrates agents (and other
/// orchestrators) — as a flow entry point, or (later) as an agent tool.
public protocol RTSOrchestratorNode: RTSFunctionNode {
    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput
}

public extension RTSOrchestratorNode {
    /// `RTSNode` requirement. The real work happens in `run(_:context:)`; the invoker
    /// always takes that path for an orchestrator, so this default is never used.
    func invoke() async throws -> RTSOutput { [:] }
}

/// Handle passed to an `RTSOrchestratorNode.run`, letting it invoke agents and other
/// orchestrators so they are drawn as its children in the trace.
///
/// Each call draws an edge `thisNode → target`. Agents/functions invoked through a
/// context get their sessions built on demand and subscribed to the flow's collector.
public struct RTSRunContext: Sendable {
    let invoker: RTSNodeInvoker
    let makeSession: @Sendable (any RTSAgentNode) throws -> RTSLLMSession
    let onNewSession: @Sendable (RTSLLMSession) -> Void
    /// The node that owns this context — the parent for the edges its `call`s draw.
    let createdBy: any RTSNode

    init(
        invoker: RTSNodeInvoker,
        makeSession: @escaping @Sendable (any RTSAgentNode) throws -> RTSLLMSession,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void,
        createdBy: any RTSNode
    ) {
        self.invoker = invoker
        self.makeSession = makeSession
        self.onNewSession = onNewSession
        self.createdBy = createdBy
    }

    /// Invoke an agent with a prompt; returns its text result.
    public func call(
        _ agent: some RTSAgentNode,
        prompt: String,
        systemMessage: String? = nil
    ) async throws -> String {
        var input = agent.inputs
        input[agent.inputKeyPrompt] = .string(prompt)
        if let systemMessage {
            input[agent.inputKeySystemMessage] = .string(systemMessage)
        }
        let output = try await call(agent, input: input)
        guard case let .string(result) = output[agent.outputKeyResult] else {
            throw RTSError.missingOutput("Agent \(agent.agentName) missing result")
        }
        return result
    }

    /// Invoke an agent with a full input dict; returns its full output.
    public func call(_ agent: some RTSAgentNode, input: RTSInput) async throws -> RTSOutput {
        let session = try makeSession(agent)
        onNewSession(session)
        return try await invoker.invokeAgent(agent, input: input, session: session, createdBy: createdBy)
    }

    /// Invoke another orchestrating function node; returns its full output.
    public func call(_ node: some RTSOrchestratorNode, input: RTSInput) async throws -> RTSOutput {
        let childContext = RTSRunContext(
            invoker: invoker,
            makeSession: makeSession,
            onNewSession: onNewSession,
            createdBy: node                 // the child's own calls parent to the child
        )
        return try await invoker.invokeFunction(
            node,
            input: input,
            context: childContext,
            createdBy: createdBy            // edge: this node → child node
        )
    }
}
