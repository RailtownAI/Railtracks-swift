//
//  RTSLLMProvider.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-29.
//

import Foundation
import Conduit

/// Type-safe strings for openAI model ID
public enum RTSOpenAIModelID {
    // GPT-4 series
    case gpt4o
    case gpt4oMini
    case gpt4Turbo
    case gpt4
    // GPT-3.5 series
    case gpt35Turbo
    // Reasoning models
    case o1
    case o1Mini
    case o3Mini
    // GPT-5 series
    case gpt5
    case gpt5Mini
    case gpt5Nano
    case gpt5_1
    case gpt5_1Codex
    case gpt5_1CodexMax
    case gpt5_2
    case gpt5_2ChatLatest
    case gpt5_2Codex
    case gpt5_2Pro
    case gpt5_4
    case gpt5_4Mini

    public var modelIDString: String {
        switch self {
        case .gpt4o:           return OpenAIModelID.gpt4o.rawValue
        case .gpt4oMini:       return OpenAIModelID.gpt4oMini.rawValue
        case .gpt4Turbo:       return OpenAIModelID.gpt4Turbo.rawValue
        case .gpt4:            return OpenAIModelID.gpt4.rawValue
        case .gpt35Turbo:      return OpenAIModelID.gpt35Turbo.rawValue
        case .o1:              return OpenAIModelID.o1.rawValue
        case .o1Mini:          return OpenAIModelID.o1Mini.rawValue
        case .o3Mini:          return OpenAIModelID.o3Mini.rawValue
        case .gpt5:            return OpenAIModelID.gpt5.rawValue
        case .gpt5Mini:        return OpenAIModelID.gpt5Mini.rawValue
        case .gpt5Nano:        return OpenAIModelID.gpt5Nano.rawValue
        case .gpt5_1:          return OpenAIModelID.gpt5_1.rawValue
        case .gpt5_1Codex:     return OpenAIModelID.gpt5_1Codex.rawValue
        case .gpt5_1CodexMax:  return OpenAIModelID.gpt5_1CodexMax.rawValue
        case .gpt5_2:          return OpenAIModelID.gpt5_2.rawValue
        case .gpt5_2ChatLatest: return OpenAIModelID.gpt5_2ChatLatest.rawValue
        case .gpt5_2Codex:     return OpenAIModelID.gpt5_2Codex.rawValue
        case .gpt5_2Pro:       return OpenAIModelID.gpt5_2Pro.rawValue
        case .gpt5_4:          return OpenAIModelID.gpt5_4.rawValue
        case .gpt5_4Mini:      return OpenAIModelID.gpt5_4Mini.rawValue
        }
    }
}

/// Provider kind without model information — used as dictionary key for API keys
public enum RTSLLMProviderKind: Hashable, Sendable {
    case openAI
    case appleAI
    // TODO: complete the rest of the cases
}

/// LLM Providers that store model ID as string in its associated value
public enum RTSLLMProvider: CustomStringConvertible, Sendable {
    case openAI(modelIDString: String)
    case appleAI
    // TODO: complete the rest of the cases
    
    public var description: String {
        switch self {
        case .openAI(let modelIDString):
            return "OpenAI-\(modelIDString)"
        case .appleAI:
            return "AppleAI-AppleFoundationModel-on-device"
        }
    }

    public var providerName: String {
        switch self {
        case .openAI: 
            return "OpenAI"
        case .appleAI: 
            return "AppleAI"
        }
    }

    public var kind: RTSLLMProviderKind {
        switch self {
        case .openAI:
            return .openAI
        case .appleAI:
            return .appleAI
        }
    }
    
    var requireAPIKeys: Bool {
        switch self {
        case .openAI:
            return true
        case .appleAI:
            return false
        }
    }
}
