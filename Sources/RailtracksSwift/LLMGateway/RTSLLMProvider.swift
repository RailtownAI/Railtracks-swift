//
//  RTSLLMProvider.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-29.
//

import Foundation
import ConduitAdvanced

/// Type-safe strings for openAI model ID
public enum RTSOpenAIModelID {
    case gpt4o
    // TODO: complete the rest of the cases
    
    public var modelIDString: String {
        switch self {
        case .gpt4o:
            return OpenAIModelID.gpt4o.rawValue
        }
    }
}

/// LLM Providers that store model ID as string in its associated value
public enum RTSLLMProvider: CustomStringConvertible, Sendable {
    case openAI(modelIDString: String)
    // TODO: complete the rest of the cases
    
    public var description: String {
        switch self {
        case .openAI(let modelIDString):
            return "OpenAI-\(modelIDString)"
        }
    }

    public var providerName: String {
        switch self {
        case .openAI: return "OpenAI"
        }
    }
}
