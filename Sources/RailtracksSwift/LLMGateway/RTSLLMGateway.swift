//
//  RTSLLMGateway.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-28.
//

import Foundation
import Conduit

/// Encapsulation layer for against the LLM connection service underneath
/// If the llm model accessing library underneath is replaced, only files under LLMGateway directory should require update while the rest  can remain the same
public class RTSLLMGateway {
    private let apiKeys: [RTSLLMProviderKind: String]

    public init(apiKeys: [RTSLLMProviderKind: String]) {
        self.apiKeys = apiKeys
    }

    func session(
        invoker: RTSNodeInvoker,
        agentNode: any RTSAgentNode,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void
    ) throws -> RTSLLMSession {
        try Self.buildSession(apiKeys: apiKeys, invoker: invoker, agentNode: agentNode, onNewSession: onNewSession)
    }

    private static func buildSession(
        apiKeys: [RTSLLMProviderKind: String],
        invoker: RTSNodeInvoker,
        agentNode: any RTSAgentNode,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void
    ) throws -> RTSLLMSession {
        let conduitTools: [any Tool] = agentNode.tools.map { tool in
            if let agentTool = tool as? RTSAgentTool {
                let makeSession: @Sendable () throws -> RTSLLMSession = {
                    try RTSLLMGateway.buildSession(
                        apiKeys: apiKeys,
                        invoker: invoker,
                        agentNode: agentTool.wrappedAgent,
                        onNewSession: onNewSession
                    )
                }
                return RTSConduitAgentToolBridge(
                    agentTool: agentTool,
                    makeSession: makeSession,
                    onNewSession: onNewSession,
                    nodeInvoker: invoker,
                    createdBy: agentNode
                )
            } else {
                return tool.asConduitTool(invoker: invoker, createdBy: agentNode)
            }
        }

        let provider = agentNode.llmProvider
        guard let apiKey = apiKeys[provider.kind] else {
            throw RTSError.missingAPIKey("No API key provided for \(provider.providerName)")
        }
        switch provider {
        case .openAI(modelIDString: let modelIDString):
            let openAIProvider = OpenAIProvider(apiKey: apiKey)
            let model = ModelIdentifier.openAI(modelIDString)
            return try RTSLLMSession.build(provider: openAIProvider, model: model, agentNode: agentNode, conduitTools: conduitTools)
        }
    }
}

extension Model: @retroactive CustomStringConvertible {
    public var description: String {
        return "\(family.description)-\(id)"
    }
}

extension Model.Family: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .mlx:
            return "mlx"
        case .mlxLocal:
            return "mlxLocal"
        case .llama:
            return "llama"
        case .coreML:
            return "coreML"
        case .foundationModels:
            return "foundationModels"
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "anthropic"
        case .huggingFace:
            return "huggingFace"
        case .kimi:
            return "kimi"
        case .miniMax:
            return "miniMax"
        case .custom:
            return "Custom"
        case .gemini:
            return "gemini"
        }
    }
}
