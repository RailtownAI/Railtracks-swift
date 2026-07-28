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

/// Type-safe strings for Anthropic model IDs (encapsulates Conduit's `AnthropicModelID`).
public enum RTSAnthropicModelID {
    // Claude 4.6
    case claudeOpus46
    case claudeSonnet46
    // Claude 4.5
    case claudeOpus45
    case claudeSonnet45
    // Claude 4.x
    case claudeOpus41
    case claudeOpus4
    case claudeSonnet4
    // Claude Haiku 4.5
    case claudeHaiku45
    // Claude 3.7
    case claude37Sonnet
    // Claude 3.5
    case claude35Sonnet
    case claude35Haiku
    // Claude 3
    case claude3Opus
    case claude3Sonnet
    case claude3Haiku

    public var modelIDString: String {
        switch self {
        case .claudeOpus46:   return AnthropicModelID.claudeOpus46.rawValue
        case .claudeSonnet46: return AnthropicModelID.claudeSonnet46.rawValue
        case .claudeOpus45:   return AnthropicModelID.claudeOpus45.rawValue
        case .claudeSonnet45: return AnthropicModelID.claudeSonnet45.rawValue
        case .claudeOpus41:   return AnthropicModelID.claudeOpus41.rawValue
        case .claudeOpus4:    return AnthropicModelID.claudeOpus4.rawValue
        case .claudeSonnet4:  return AnthropicModelID.claudeSonnet4.rawValue
        case .claudeHaiku45:  return AnthropicModelID.claudeHaiku45.rawValue
        case .claude37Sonnet: return AnthropicModelID.claude37Sonnet.rawValue
        case .claude35Sonnet: return AnthropicModelID.claude35Sonnet.rawValue
        case .claude35Haiku:  return AnthropicModelID.claude35Haiku.rawValue
        case .claude3Opus:    return AnthropicModelID.claude3Opus.rawValue
        case .claude3Sonnet:  return AnthropicModelID.claude3Sonnet.rawValue
        case .claude3Haiku:   return AnthropicModelID.claude3Haiku.rawValue
        }
    }
}

/// Type-safe strings for Gemini model IDs.
///
/// Unlike `RTSOpenAIModelID` / `RTSAnthropicModelID`, Conduit ships **no** `GeminiModelID` type to
/// encapsulate — its `GeminiProvider` accepts an arbitrary model string and places it directly in the
/// request path (`models/{id}:generateContent`). These raw strings are therefore maintained here by
/// hand and must be updated as Google publishes / retires models.
public enum RTSGeminiModelID {
    // Gemini 3
    case gemini3Pro
    case gemini3Flash
    // Gemini 2.5
    case gemini25Pro
    case gemini25Flash
    case gemini25FlashLite
    // Gemini 2.0
    case gemini20Flash
    case gemini20FlashLite
    // Gemini 1.5
    case gemini15Pro
    case gemini15Flash
    case gemini15Flash8B

    public var modelIDString: String {
        switch self {
        case .gemini3Pro:        return "gemini-3-pro-preview"
        case .gemini3Flash:      return "gemini-3-flash-preview"
        case .gemini25Pro:       return "gemini-2.5-pro"
        case .gemini25Flash:     return "gemini-2.5-flash"
        case .gemini25FlashLite: return "gemini-2.5-flash-lite"
        case .gemini20Flash:     return "gemini-2.0-flash"
        case .gemini20FlashLite: return "gemini-2.0-flash-lite"
        case .gemini15Pro:       return "gemini-1.5-pro"
        case .gemini15Flash:     return "gemini-1.5-flash"
        case .gemini15Flash8B:   return "gemini-1.5-flash-8b"
        }
    }
}

/// Provider kind without model information — used as dictionary key for API keys
public enum RTSLLMProviderKind: Hashable, CaseIterable, Sendable {
    case openAI
    case anthropic
    case gemini
    case appleAI
}

/// LLM Providers that store model ID as string in its associated value
public enum RTSLLMProvider: CustomStringConvertible, CaseIterable, Sendable {
    case openAI(modelIDString: String)
    case anthropic(modelIDString: String)
    case gemini(modelIDString: String)
    case appleAI

    public var description: String {
        switch self {
        case .openAI(let modelIDString):
            return "OpenAI-\(modelIDString)"
        case .anthropic(let modelIDString):
            return "Anthropic-\(modelIDString)"
        case .gemini(let modelIDString):
            return "Gemini-\(modelIDString)"
        case .appleAI:
            return "AppleAI-AppleFoundationModel-on-device"
        }
    }

    public var providerName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        case .appleAI:
            return "AppleAI"
        }
    }

    public var kind: RTSLLMProviderKind {
        switch self {
        case .openAI:
            return .openAI
        case .anthropic:
            return .anthropic
        case .gemini:
            return .gemini
        case .appleAI:
            return .appleAI
        }
    }

    public var modelID: String {
        switch self {
        case .openAI(let modelIDString):
            return modelIDString
        case .anthropic(let modelIDString):
            return modelIDString
        case .gemini(let modelIDString):
            return modelIDString
        case .appleAI:
            return "on-device"
        }
    }

    public var isLocal: Bool {
        switch self {
        case .appleAI:
            return true
        case .openAI, .anthropic, .gemini:
            return false
        }
    }

    /// Returns whether a provider name string belongs to a local (zero-cost) provider.
    /// Used by the JSON export layer, which only has the name string from message metadata.
    static func isLocal(providerName: String) -> Bool {
        return allCases.first { $0.providerName == providerName }?.isLocal ?? false
    }

    public static var allCases: [RTSLLMProvider] {
        RTSLLMProviderKind.allCases.map { kind in
            switch kind {
            case .openAI:
                return .openAI(modelIDString: "")
            case .anthropic:
                return .anthropic(modelIDString: "")
            case .gemini:
                return .gemini(modelIDString: "")
            case .appleAI:
                return .appleAI
            }
        }
    }
}
