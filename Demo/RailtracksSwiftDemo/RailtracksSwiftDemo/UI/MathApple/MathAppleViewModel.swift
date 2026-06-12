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
@Observable
class MathAppleViewModel {
    let prompt: String = "What is 50 + 20 x 8 - 4? Give me the final answer in a single number without any description."
    var promptResult: String = ""
    var isRunning = false

    func startPrompt() {
        let prompt = self.prompt
        isRunning = true
        Task { [weak self] in
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
                systemMessage: "You are a Math assistant. " +
                "If there is addition in the math, you must use the provided addition tool to perform the calculation. " +
                "If there is subtraction in the math, you must use the provided subtraction tool to perform the calculation. " +
                "If there is multiplication in the math, you must use the provided multiplication tool to perform the calculation. " +
                "If there is division in the math, you must use the provided division tool to perform the calculation. " +
                "You will use the tools in proper sequence and wait for result of multiplication and division tools before using addition and subtraction tools." +
                "You must use these tools one at a time and not run them in parallel." +
                "You will calculate simple math problem asked by user."
            )

            Log.debug("starting prompt, waiting for response...")
            self?.promptResult = (try? await flow.run(agent: agent, prompt: prompt, gateway: gateway)) ?? "n/a"
            Log.debug("obtained prompt result")
            self?.isRunning = false
        }
    }
}
