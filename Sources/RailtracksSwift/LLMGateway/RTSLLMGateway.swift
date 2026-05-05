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
    private let sessionBuilder: ([any RTSToolNode]) -> RTSLLMSession
    let llmModel: ModelIdentifier
    
    public var modelDescription: String {
        return llmModel.description
    }
                                                                                                                                       
    public init?(llmProvider: RTSLLMProvider, apiKey: String) {
        switch llmProvider {
        case .openAI(modelIDString: let modelIDString):
            let provider = OpenAIProvider(apiKey: apiKey)
//            let model = OpenAIModelID(modelIDString)
            let model = ModelIdentifier.openAI(modelIDString)
            self.llmModel = model
            self.sessionBuilder = { tools in
                RTSLLMSession.build(provider: provider, model: model, tools: tools)
            }
        }
    }
     
    public func session(tools: [any RTSToolNode] = []) -> RTSLLMSession {
        sessionBuilder(tools)
    }
}
//public class RTSLLMGateway {
//    let accessPoint: Conduit
//    let llmModel: Model
//    
//    public var modelDescription: String {
//        return llmModel.description
//    }
//    
//    public init?(llmProvider: RTSLLMProvider, apiKey: String) {
//        switch llmProvider {
//        case .openAI(modelIDString: let modelIDString):
//            self.accessPoint = Conduit(.openAI(apiKey: apiKey))
//            self.llmModel = Model.openAI(modelIDString)
//        }
//    }
//    
//    public func session(tools: [any RTSToolNode] = []) throws -> RTSLLMSession {
//        return try RTSLLMSession(
//            accessPoint: accessPoint,
//            model: llmModel,
//            tools: tools
//        )
//    }
//}

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
