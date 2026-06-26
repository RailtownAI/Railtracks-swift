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
    }

    var libVersion: String = RailtracksSwift.version
    var mode: ViewMode = .mathVerify
    var isShowingKeyPrompt = false
    var isShowingKeyUpdate = false
    var hasOpenAIKey: Bool = false

    func checkKeychain() {
        hasOpenAIKey = KeychainHelper.readOpenAIKey().isNotNilNorEmpty
        if !hasOpenAIKey {
            isShowingKeyPrompt = true
        }
    }

    func refreshKeyStatus() {
        hasOpenAIKey = KeychainHelper.readOpenAIKey().isNotNilNorEmpty
    }
}
