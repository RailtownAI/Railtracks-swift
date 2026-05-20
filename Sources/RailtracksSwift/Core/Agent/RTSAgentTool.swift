//
//  RTSAgentTool.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-19.
//

import Foundation

public struct RTSAgentTool {
    var wrappedAgent: RTSAgentNode
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
        // placeholder, to be repalced during session build
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
}
