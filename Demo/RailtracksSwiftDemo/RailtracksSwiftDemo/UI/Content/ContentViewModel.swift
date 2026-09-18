//
//  ContentViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import RailtracksSwift

@Observable
class ContentViewModel {
    enum ViewMode {
        case simple
        case math
        @available(macOS 26, iOS 26, *)
        case mathApple
        case mathVerify
        case mathError
        case outputSchema
        case guardrails
        case evaluation
        case vision
        case rag
    }

    var libVersion: String = RailtracksSwift.version
    var mode: ViewMode = .mathVerify
    var isShowingKeyPrompt = false
    var isShowingKeyUpdate = false
    var hasAnthropicKey: Bool = false
    var hasOpenAIKey: Bool = false
    var hasGeminiKey: Bool = false
    /// Which provider the launch prompt is currently collecting.
    var promptProvider: DemoAPIKeyProvider = .anthropic
    /// Which provider the "Update" sheet is editing.
    var updateProvider: DemoAPIKeyProvider = .anthropic

    /// Prompt for any missing key, one provider at a time (re-checked after each save, so each gets
    /// collected). Anthropic first (most demos), then Gemini (Math), then OpenAI (MathVerify).
    func checkKeychain() {
        refreshKeyStatus()
        if !hasAnthropicKey {
            promptProvider = .anthropic
            isShowingKeyPrompt = true
        } else if !hasGeminiKey {
            promptProvider = .gemini
            isShowingKeyPrompt = true
        } else if !hasOpenAIKey {
            promptProvider = .openAI
            isShowingKeyPrompt = true
        }
    }

    func refreshKeyStatus() {
        hasAnthropicKey = KeychainHelper.readAnthropicKey().isNotNilNorEmpty
        hasOpenAIKey = KeychainHelper.readOpenAIKey().isNotNilNorEmpty
        hasGeminiKey = KeychainHelper.readGeminiKey().isNotNilNorEmpty
    }
}
