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

    func session(invoker: RTSNodeInvoker, agentNode: any RTSAgentNode) -> (RTSLLMSession, [RTSLLMSession]) {
        buildSession(invoker: invoker, agentNode: agentNode)
    }

    private func buildSession(invoker: RTSNodeInvoker, agentNode: any RTSAgentNode) -> (RTSLLMSession, [RTSLLMSession]) {
        var allSubSessions: [RTSLLMSession] = []

        let conduitTools: [any Tool] = agentNode.tools.map { tool in
            if let agentTool = tool as? RTSAgentTool {
                let (subSession, deeperSubSessions) = buildSession(invoker: invoker, agentNode: agentTool.wrappedAgent)
                allSubSessions.append(subSession)
                allSubSessions.append(contentsOf: deeperSubSessions)
                return RTSConduitAgentToolBridge(
                    agentTool: agentTool,
                    subSession: subSession,
                    nodeInvoker: invoker,
                    createdBy: agentNode
                )
            } else {
                return tool.asConduitTool(invoker: invoker, createdBy: agentNode)
            }
        }

        let provider = agentNode.llmProvider
        guard let apiKey = apiKeys[provider.kind] else {
            fatalError("No API key provided for \(provider.providerName)")
        }
        switch provider {
        case .openAI(modelIDString: let modelIDString):
            let openAIProvider = OpenAIProvider(apiKey: apiKey)
            let model = ModelIdentifier.openAI(modelIDString)
            let session = RTSLLMSession.build(provider: openAIProvider, model: model, agentNode: agentNode, conduitTools: conduitTools)
            return (session, allSubSessions)
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
