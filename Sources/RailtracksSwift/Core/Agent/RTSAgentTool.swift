//
//  RTSAgentTool.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-19.
//

import Foundation

public struct RTSAgentTool: Sendable {
    var wrappedAgent: any RTSAgentNode
    let description: String
    let parameters: RTSToolSchema
    public var callableRoutine: RTSClosure

    public init(
        agent: any RTSAgentNode,
        description: String,
        parameters: RTSToolSchema
    ) {
        self.wrappedAgent = agent
        self.description = description
        self.parameters = parameters
        self.callableRoutine = RTSClosure { _ in [:] }
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
