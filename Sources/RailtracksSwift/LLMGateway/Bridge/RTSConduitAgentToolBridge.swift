//
//  RTSConduitAgentToolBridge.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-19.
//

import Foundation
import Conduit

struct RTSConduitAgentToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    private let agentTool: RTSAgentTool
    private let makeSession: @Sendable () throws -> RTSLLMSession
    private let onNewSession: @Sendable (RTSLLMSession) -> Void
    private let nodeInvoker: RTSNodeInvoker
    private let createdBy: any RTSAgentNode

    init(
        agentTool: RTSAgentTool,
        makeSession: @escaping @Sendable () throws -> RTSLLMSession,
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
        let systemKey = agentTool.wrappedAgent.inputKeySystemMessage
        let systemMessage = input[systemKey]
        if let transform = agentTool.inputTransform {
            input = try await transform(input)
        }
        if let systemMessage, input[systemKey] == nil {
            input[systemKey] = systemMessage
        }
        let promptKey = agentTool.wrappedAgent.inputKeyPrompt
        if input[promptKey] == nil {
            log.warning("⚠️ 🌁 '\(agentTool.name())' has no '\(promptKey)' in input — auto-wrapping all parameters as JSON string under '\(promptKey)'")
            if let data = try? JSONEncoder().encode(input),
               let json = String(data: data, encoding: .utf8) {
                input[promptKey] = .string(json)
            }
        }
        let session = try makeSession()
        onNewSession(session)
        var output = try await nodeInvoker.invokeAgent(
            agentTool.wrappedAgent,
            input: input,
            session: session,
            createdBy: createdBy
        )
        if let transform = agentTool.outputTransform {
            output = try await transform(output)
        }
        guard let data = try? JSONEncoder().encode(output),
              let result = String(data: data, encoding: .utf8) else {
            throw RTSError.encodingFailed()
        }
        return result
    }
}
