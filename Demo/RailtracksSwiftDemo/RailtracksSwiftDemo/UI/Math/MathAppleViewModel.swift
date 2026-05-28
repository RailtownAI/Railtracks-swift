//
//  MathAppleViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation
import RailtracksSwift
import Logging

/// Math agent demo using Apple on-device LLM via RTSAgent(llmProvider: .appleAI).
@Observable
class MathAppleViewModel {
    let prompt: String = "What is 50 + 20 x 8 - 4? Give me the final answer in a single number without any description."
    var promptResult: String = ""

    func startPrompt() {
        let prompt = self.prompt
        Task { [weak self] in
            self?.promptResult = "waiting..."
            let gateway = RTSLLMGateway(apiKeys: [:])

            let tools: [any RTSToolNode] = [
                AdditionTool(),
                SubtractionTool(),
                MultiplicationTool(),
                DivisionTool()
            ]

            let flow = RTSFlow(title: "Math Assistant (AppleAI)")

            let agent = RTSAgent(
                llmProvider: .appleAI,
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
        }
    }
}
