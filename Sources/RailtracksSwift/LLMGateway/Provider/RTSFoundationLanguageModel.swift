//
//  RTSFoundationLanguageModel.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-24.
//

import Foundation
import FoundationModels

/// Any FoundationModels `LanguageModel`, for use with `RTSLLMProvider.foundationModel`.
///
/// Lets an agent run on a third-party model that plugs into Apple's `LanguageModelSession` —
/// for example Anthropic's `ClaudeLanguageModel` from `ClaudeForFoundationModels`:
///
/// ```swift
/// let claude = ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey(apiKey))
/// let agent = RTSAgent(
///     llmProvider: .foundationModel(
///         RTSFoundationLanguageModel(claude, kind: .anthropic, modelID: "claude-sonnet-4-6")
///     ),
///     name: "Support"
/// )
/// ```
///
/// RailtracksSwift depends only on Apple's protocol, never on a vendor package, so the app owns
/// that dependency — and the OS 27 deployment target that comes with it.
///
/// Meant for third-party models. Apple's own have dedicated cases, `RTSLLMProvider.appleAI` and
/// `RTSLLMProvider.privateCloudCompute(options:)`, which need no app-side `#available` check,
/// always label correctly, and (for Private Cloud Compute) accept a reasoning level.
///
/// The model is stored type-erased, so `RTSLLMProvider` carries no availability annotation; only
/// this initializer does.
///
/// Built with an SDK older than OS 27 (Xcode 26), `LanguageModel` does not exist, so neither does
/// the initializer: the type is there, keeping `RTSLLMProvider.foundationModel` in every build, but
/// nothing can construct it.
public struct RTSFoundationLanguageModel: Sendable {
    /// Who serves the model — not how it is reached. Claude through Foundation Models is
    /// `.anthropic`, which makes pricing, `llm.*` events, the flow-graph trace and the evaluation
    /// concurrency limiter treat it exactly like a Conduit Anthropic call. The limiter sharing is
    /// correct, not incidental: both paths spend the same API key's rate limit.
    public let kind: RTSLLMProviderKind
    /// The pricing key, e.g. `"claude-sonnet-4-6"` — the same identifier the Conduit case of the
    /// same provider uses, so both paths price identically.
    public let modelID: String
    /// Always an `any LanguageModel`, set only by the OS 27 initializer.
    let model: any Sendable

    // XCODE26-SDK: `LanguageModel` exists only in the OS 27 SDK (Xcode 27, Swift 6.4).
    #if compiler(>=6.4)
    @available(macOS 27, iOS 27, *)
    public init(
        _ model: some LanguageModel,
        kind: RTSLLMProviderKind,
        modelID: String
    ) {
        self.model = model
        self.kind = kind
        self.modelID = modelID
    }
    #endif
}

// XCODE26-SDK: as above — this builds on `LanguageModel` and `init(model:tools:instructions:)`.
#if compiler(>=6.4)
@available(macOS 27, iOS 27, *)
extension RTSFoundationLanguageModel {
    /// A factory building each `LanguageModelSession` on this model, for `AppleAISession`.
    func sessionFactory() throws -> AppleAISession.MakeSession {
        // Unreachable in practice: the only initializer stores a `LanguageModel`.
        guard let languageModel = model as? any LanguageModel else {
            throw RTSError.providerUnavailable("\(type(of: model)) is not a FoundationModels LanguageModel")
        }
        return { instructions, tools in
            LanguageModelSession(model: languageModel, tools: tools, instructions: instructions)
        }
    }
}
#endif
