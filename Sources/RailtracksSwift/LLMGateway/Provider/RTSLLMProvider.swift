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
/// Verified against `GET /v1beta/models` on 2026-08-14. Google retires Gemini models aggressively —
/// the 1.5 and 2.0 families and `gemini-3-pro-preview` were all live when first written here and have
/// since been shut down — so re-check this list against that endpoint rather than trusting it.
public enum RTSGeminiModelID {
    // Gemini 3.x
    case gemini37Flash
    case gemini36Flash
    case gemini35Flash
    case gemini35FlashLite
    case gemini31Pro
    case gemini31FlashLite
    case gemini3Flash
    // Gemini 2.5
    case gemini25Pro
    case gemini25Flash
    case gemini25FlashLite
    // Floating aliases — always the current model of that tier. Useful precisely because the pinned
    // identifiers above go stale; the trade is that the model can change under you.
    case proLatest
    case flashLatest
    case flashLiteLatest

    public var modelIDString: String {
        switch self {
        case .gemini37Flash:     return "gemini-3.7-flash"
        case .gemini36Flash:     return "gemini-3.6-flash"
        case .gemini35Flash:     return "gemini-3.5-flash"
        case .gemini35FlashLite: return "gemini-3.5-flash-lite"
        case .gemini31Pro:       return "gemini-3.1-pro-preview"
        case .gemini31FlashLite: return "gemini-3.1-flash-lite"
        case .gemini3Flash:      return "gemini-3-flash-preview"
        case .gemini25Pro:       return "gemini-2.5-pro"
        case .gemini25Flash:     return "gemini-2.5-flash"
        case .gemini25FlashLite: return "gemini-2.5-flash-lite"
        case .proLatest:         return "gemini-pro-latest"
        case .flashLatest:       return "gemini-flash-latest"
        case .flashLiteLatest:   return "gemini-flash-lite-latest"
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
    case gemini(modelIDString: String, options: RTSGeminiOptions = RTSGeminiOptions())
    case appleAI
    /// Any FoundationModels `LanguageModel` — e.g. Claude via `ClaudeForFoundationModels` —
    /// run through `LanguageModelSession`. Requires macOS 27 / iOS 27 at run time.
    ///
    /// Reports the wrapped model's `kind` as its own, so it is priced, traced and rate-limited
    /// as that provider. It is therefore absent from `allCases`, which lists one case per kind.
    case foundationModel(RTSFoundationLanguageModel)

    public var description: String {
        switch self {
        case .openAI(let modelIDString):
            return "OpenAI-\(modelIDString)"
        case .anthropic(let modelIDString):
            return "Anthropic-\(modelIDString)"
        case .gemini(let modelIDString, _):
            return "Gemini-\(modelIDString)"
        case .appleAI:
            return "AppleAI-AppleFoundationModel-on-device"
        case .foundationModel(let languageModel):
            return "FoundationModels-\(providerName)-\(languageModel.modelID)"
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
        case .foundationModel(let languageModel):
            // `allCases` holds exactly one case per kind, so this always finds one.
            return Self.allCases.first { $0.kind == languageModel.kind }?.providerName ?? "Unknown"
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
        case .foundationModel(let languageModel):
            return languageModel.kind
        }
    }

    public var modelID: String {
        switch self {
        case .openAI(let modelIDString):
            return modelIDString
        case .anthropic(let modelIDString):
            return modelIDString
        case .gemini(let modelIDString, _):
            return modelIDString
        case .appleAI:
            return "on-device"
        case .foundationModel(let languageModel):
            return languageModel.modelID
        }
    }

    public var isLocal: Bool {
        switch self {
        case .appleAI:
            return true
        case .openAI, .anthropic, .gemini:
            return false
        case .foundationModel(let languageModel):
            return languageModel.kind == .appleAI
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
