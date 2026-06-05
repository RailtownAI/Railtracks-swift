//
//  RTSAppleAIAgentToolBridge.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-02.
//

import Foundation
import FoundationModels

/// Wraps an `RTSAgentTool` as a FoundationModels `Tool` so an Apple AI agent can
/// invoke a sub-agent as part of its tool set. Mirrors `RTSConduitAgentToolBridge`.
///
/// Uses `GeneratedContent` as `Arguments` — valid because `GeneratedContent: Generable`,
/// satisfying the `Arguments: ConvertibleFromGeneratedContent` constraint. The parameter
/// schema is built dynamically from `RTSToolSchema` via `DynamicGenerationSchema`.
struct RTSAppleAIAgentToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let agentTool: RTSAgentTool
    private let makeSession: @Sendable () throws -> RTSLLMSession
    private let onNewSession: @Sendable (RTSLLMSession) -> Void
    private let nodeInvoker: RTSNodeInvoker
    private let createdBy: any RTSAgentNode

    init(
        agentTool: RTSAgentTool,
        parameters: GenerationSchema,
        makeSession: @escaping @Sendable () throws -> RTSLLMSession,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void,
        nodeInvoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode
    ) {
        self.name = agentTool.name()
        self.description = agentTool.toolDescription
        self.parameters = parameters
        self.agentTool = agentTool
        self.makeSession = makeSession
        self.onNewSession = onNewSession
        self.nodeInvoker = nodeInvoker
        self.createdBy = createdBy
    }

    func call(arguments: GeneratedContent) async throws -> String {
        log.debug("🍎 RTSAppleAIAgentToolBridge - \(agentTool.name()) is called with \(arguments.jsonString)")
        var input = agentTool.wrappedAgent.inputs
        for param in agentTool.parameters.parameters {
            switch param.type {
            case .string:
                if let value = try? arguments.value(String.self, forProperty: param.name) {
                    input[param.name] = .string(value)
                }
            case .number:
                if let value = try? arguments.value(Double.self, forProperty: param.name) {
                    input[param.name] = .number(value)
                }
            case .bool:
                if let value = try? arguments.value(Bool.self, forProperty: param.name) {
                    input[param.name] = .bool(value)
                }
            case .array(let elementType):
                switch elementType {
                case .string:
                    if let value = try? arguments.value([String].self, forProperty: param.name) {
                        input[param.name] = .array(value.map { .string($0) })
                    }
                case .number:
                    if let value = try? arguments.value([Double].self, forProperty: param.name) {
                        input[param.name] = .array(value.map { .number($0) })
                    }
                case .bool:
                    if let value = try? arguments.value([Bool].self, forProperty: param.name) {
                        input[param.name] = .array(value.map { .bool($0) })
                    }
                case .array:
                    break
                }
            }
        }
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
            log.warning("⚠️ 🍎 '\(agentTool.name())' has no '\(promptKey)' in input — auto-wrapping all parameters as JSON string under '\(promptKey)'")
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
