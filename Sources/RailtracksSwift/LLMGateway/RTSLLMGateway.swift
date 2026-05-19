//
//  RTSLLMGateway.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-28.
//

import Foundation
import ConduitAdvanced

/// Encapsulation layer for against the LLM connection service underneath
/// If the llm model accessing library underneath is replaced, only files under LLMGateway directory should require update while the rest  can remain the same
public class RTSLLMGateway {
    private let apiKey: String
    private let defaultProvider: RTSLLMProvider
    let llmModel: ModelIdentifier

    public var modelDescription: String {
        return llmModel.description
    }

    public init?(llmProvider: RTSLLMProvider, apiKey: String) {
        self.apiKey = apiKey
        self.defaultProvider = llmProvider
        switch llmProvider {
        case .openAI(modelIDString: let modelIDString):
            self.llmModel = ModelIdentifier.openAI(modelIDString)
        }
    }

    func session(invoker: RTSNodeInvoker, agentNode: any RTSAgentNode) -> RTSLLMSession {
        buildSession(invoker: invoker, agentNode: agentNode, provider: agentNode.llmProvider)
    }

    private func buildSession(invoker: RTSNodeInvoker, agentNode: any RTSAgentNode, provider: RTSLLMProvider) -> RTSLLMSession {
        switch provider {
        case .openAI(modelIDString: let modelIDString):
            let openAIProvider = OpenAIProvider(apiKey: apiKey)
            let model = ModelIdentifier.openAI(modelIDString)
            return RTSLLMSession.build(provider: openAIProvider, model: model, tools: agentNode.tools, invoker: invoker, agentNode: agentNode)
        }
    }
}

extension Model: CustomStringConvertible {
    public var description: String {
        return "\(family.description)-\(id)"
    }
}

extension Model.Family: CustomStringConvertible {
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
        }
    }
}
