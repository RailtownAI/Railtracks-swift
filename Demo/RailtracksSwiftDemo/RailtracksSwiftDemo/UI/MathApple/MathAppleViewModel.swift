//
//  MathAppleViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation
import FoundationModels
import RailtracksSwift
import Logging

/// Math agent demo using Apple on-device LLM via RTSAgent(llmProvider: .appleAI).
@available(macOS 26, iOS 26, *)
@Observable
class MathAppleViewModel {
    let prompt: String = MathToolsPrompt.prompt
    var promptResult: String = ""
    var isRunning = false

    func startPrompt() {
        let prompt = self.prompt
        isRunning = true
        Task { [weak self] in
            defer { self?.isRunning = false }
            switch SystemLanguageModel.default.availability {
            case .available:
                break
            case .unavailable(let reason):
                let message: String
                switch reason {
                case .appleIntelligenceNotEnabled:
                    message = "Apple Intelligence is not enabled. Go to Settings → Apple Intelligence & Siri to enable it."
                case .deviceNotEligible:
                    message = "This device does not support Apple Intelligence."
                case .modelNotReady:
                    message = "Apple Intelligence model is not ready yet. Please wait for it to finish downloading."
                default:
                    message = "Apple Intelligence is unavailable: \(reason)"
                }
                self?.promptResult = message
                return
            }

            self?.promptResult = "waiting..."
            let gateway = RTSLLMGateway(apiKeys: [:])

            let tools: [any RTSToolNode] = [
                AdditionToolApple(),
                SubtractionToolApple(),
                MultiplicationToolApple(),
                DivisionToolApple()
            ]

            let flow = RTSFlow(title: "Math Assistant (AppleAI)")

            let agent = RTSAgent(
                llmProvider: .appleAI,
                name: "AppleAI Math Assistant Agent",
                tools: tools,
                systemMessage: MathToolsPrompt.systemMessage
            )

            Log.debug("starting prompt, waiting for response...")
            self?.promptResult = (try? await flow.run(agent: agent, prompt: prompt, gateway: gateway)) ?? "n/a"
            Log.debug("obtained prompt result")
        }
    }
}
