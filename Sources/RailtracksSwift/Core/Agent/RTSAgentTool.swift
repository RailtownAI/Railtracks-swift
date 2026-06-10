//
//  RTSAgentTool.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-19.
//

import Foundation

/// Wraps an `RTSAgentNode` so it can be registered as a tool on a parent agent.
/// When the parent LLM decides to call this tool, a new LLM session is created for the
/// wrapped agent and its result is returned as the tool output.
public struct RTSAgentTool: Sendable {
    var wrappedAgent: any RTSAgentNode
    let description: String
    let parameters: RTSToolSchema
    /// Satisfies the `RTSToolNode` protocol requirement. Not used for invocation —
    /// agent tools are always dispatched through `RTSConduitAgentToolBridge`.
    public var callableRoutine: RTSClosure
    /// Optional closure run on the raw inputs before they are forwarded to the wrapped agent.
    /// Use to rename keys, inject context, or coerce types the wrapped agent expects.
    public var inputTransform: (@Sendable (RTSInput) async throws -> RTSInput)?
    /// Optional closure run on the wrapped agent's outputs before they are returned to the parent LLM.
    /// Use to rename keys, filter fields, or reformat the result.
    public var outputTransform: (@Sendable (RTSOutput) async throws -> RTSOutput)?

    /// - Parameters:
    ///   - agent: The agent to expose as a callable tool.
    ///   - description: Human-readable description shown to the parent LLM when deciding whether to call this tool.
    ///   - parameters: Schema describing the tool's input parameters.
    ///   - inputTransform: Optional closure to rewrite inputs before they are forwarded to the wrapped agent.
    ///   - outputTransform: Optional closure to rewrite outputs returned by the wrapped agent.
    public init(
        agent: any RTSAgentNode,
        description: String,
        parameters: RTSToolSchema,
        inputTransform: (@Sendable (RTSInput) async throws -> RTSInput)? = nil,
        outputTransform: (@Sendable (RTSOutput) async throws -> RTSOutput)? = nil
    ) {
        self.wrappedAgent = agent
        self.description = description
        self.parameters = parameters
        self.callableRoutine = RTSClosure { _ in [:] }
        self.inputTransform = inputTransform
        self.outputTransform = outputTransform
    }
}

extension RTSAgentTool: RTSToolNode {
    public var id: UUID {
        return wrappedAgent.id
    }

    public var toolName: String {
        return wrappedAgent.agentName
    }

    public var inputs: RTSInput {
        get {
            return wrappedAgent.inputs
        }
        set {
            wrappedAgent.inputs = newValue
        }
    }

    public var toolDescription: String {
        return description
    }

    public var parameterSchema: RTSToolSchema {
        return parameters
    }
    
    /**
    Summary of the call chain for a tool call:
    
    Conduit LLM runtime
      → RTSConduitToolBridge.call          (regular tool)
          → RTSNodeInvoker.invoke(RTSToolNode)
              → invokeCore { mutableNode.invoke(runID:) }
                  → RTSToolNode.invoke(runID:)
                      → RTSToolNode.invoke()
                          → callableRoutine.closure(inputs)

      → RTSConduitAgentToolBridge.call     (agent-as-tool)
          → RTSNodeInvoker.invoke(RTSAgentNode)
              → invokeCore { mutableNode.invoke(runID:session:) }
                  → RTSAgentNode.invoke(runID:session:)
                      → RTSLLMSession.run(...)
     
     AgentTool should never go through regular tool path or be called directly
     */
    public func invoke(runID: UUID) async throws -> RTSOutput {
        throw RTSError.invalidInvocation("RTSAgentTool must be invoked via RTSConduitAgentToolBridge, not directly through RTSToolNode")
    }
}
