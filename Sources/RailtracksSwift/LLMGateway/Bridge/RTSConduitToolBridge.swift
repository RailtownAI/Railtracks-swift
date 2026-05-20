//
//  RTSConduitToolBridge.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-05.
//

import Foundation
import Conduit

struct RTSConduitToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    
    internal let node: any RTSToolNode
    internal let nodeInvoker: RTSNodeInvoker
    internal let createdBy: any RTSAgentNode

    var name: String { node.name() }
    var description: String { node.toolDescription }
    var parameters: GenerationSchema { node.parameterSchema.toGenerationSchema() }

    func call(arguments: GeneratedContent) async throws -> String {
        log.debug("🌁 RTSConduitToolBridge - \(node.name()) is called with \(arguments.jsonString)")
        let jsonData = Data(arguments.jsonString.utf8)
        let input = try JSONDecoder().decode(RTSInput.self, from: jsonData)
        let output = try await nodeInvoker.invoke(node, input: input, createdBy: createdBy)
        guard let data = try? JSONEncoder().encode(output),
              let result = String(data: data, encoding: .utf8) else {
            throw RTSError.encodingFailed()
        }
        return result
    }
}

public extension RTSToolNode {
    func asConduitTool(invoker: RTSNodeInvoker, createdBy: any RTSAgentNode) -> any Tool {
        RTSConduitToolBridge(node: self, nodeInvoker: invoker, createdBy: createdBy)
    }
}

struct RTSConduitAgentToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    private let agentTool: RTSAgentTool
    private let makeSession: @Sendable () -> RTSLLMSession
    private let onNewSession: @Sendable (RTSLLMSession) -> Void
    private let nodeInvoker: RTSNodeInvoker
    private let createdBy: any RTSAgentNode

    init(
        agentTool: RTSAgentTool,
        makeSession: @escaping @Sendable () -> RTSLLMSession,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void,
        nodeInvoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode
    ) {
        self.agentTool = agentTool
        self.makeSession = makeSession
        self.onNewSession = onNewSession
        self.nodeInvoker = nodeInvoker
        self.createdBy = createdBy
    }

    var name: String { agentTool.name() }
    var description: String { agentTool.toolDescription }
    var parameters: GenerationSchema { agentTool.parameterSchema.toGenerationSchema() }

    func call(arguments: GeneratedContent) async throws -> String {
        log.debug("🌁 RTSConduitAgentToolBridge - \(agentTool.name()) is called with \(arguments.jsonString)")
        let jsonData = Data(arguments.jsonString.utf8)
        let toolArgs = try JSONDecoder().decode(RTSInput.self, from: jsonData)
        var input = agentTool.wrappedAgent.inputs
        input.merge(toolArgs) { _, new in new }
        let session = makeSession()
        onNewSession(session)
        let output = try await nodeInvoker.invoke(agentTool.wrappedAgent, input: input, session: session, createdBy: createdBy)
        guard let data = try? JSONEncoder().encode(output),
              let result = String(data: data, encoding: .utf8) else {
            throw RTSError.encodingFailed()
        }
        return result
    }
}
