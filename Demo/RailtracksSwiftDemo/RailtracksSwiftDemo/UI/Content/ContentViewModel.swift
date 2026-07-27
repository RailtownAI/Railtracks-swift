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
    }

    var libVersion: String = RailtracksSwift.version
    var mode: ViewMode = .mathVerify
    var isShowingKeyPrompt = false
    var isShowingKeyUpdate = false
    var hasAnthropicKey: Bool = false
    var hasOpenAIKey: Bool = false
    /// Which provider the launch prompt is currently collecting.
    var promptProvider: DemoAPIKeyProvider = .anthropic
    /// Which provider the "Update" sheet is editing.
    var updateProvider: DemoAPIKeyProvider = .anthropic

    /// Prompt for any missing key, one provider at a time (re-checked after each save, so both get
    /// collected). Anthropic first since most demos use it; MathVerify still uses OpenAI.
    func checkKeychain() {
        refreshKeyStatus()
        if !hasAnthropicKey {
            promptProvider = .anthropic
            isShowingKeyPrompt = true
        } else if !hasOpenAIKey {
            promptProvider = .openAI
            isShowingKeyPrompt = true
        }
    }

    func refreshKeyStatus() {
        hasAnthropicKey = KeychainHelper.readAnthropicKey().isNotNilNorEmpty
        hasOpenAIKey = KeychainHelper.readOpenAIKey().isNotNilNorEmpty
    }
}
