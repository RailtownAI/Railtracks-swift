//
//  MathViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation
import RailtracksSwift
import Logging

/// Math agent demo using OpenAI via RTSAgent(llmProvider: .openAI).
@Observable
class MathViewModel {
    let prompt: String = "What is 50 + 20 x 8 - 4? Give me the final answer in a single number without any description."
    var promptResult: String = ""
    var isRunning = false
    var isShowingKeyPrompt = false

    func startPrompt() {
        guard let apiKey = KeychainHelper.readOpenAIKey() else {
            isShowingKeyPrompt = true
            return
        }
        let prompt = self.prompt
        isRunning = true
        Task { [weak self] in
            let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])
            let tools: [any RTSToolNode] = [
                AdditionTool(),
                SubtractionTool(),
                MultiplicationTool(),
                DivisionTool()
            ]
            let flow = RTSFlow(title: "Math Assistant")
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                tools: tools,
                systemMessage: "You are a Math assistant. " +
                "If there is addition in the math, you must use the provided addition tool to perform the calculation. " +
                "If there is subtraction in the math, you must use the provided subtraction tool to perform the calculation. " +
                "If there is multiplication in the math, you must use the provided multiplication tool to perform the calculation. " +
                "If there is division in the math, you must use the provided division tool to perform the calculation. " +
                "You will calculate simple math problem asked by user."
            )
            Log.debug("starting prompt, waiting for response...")
            self?.promptResult = (try? await flow.run(agent: agent, prompt: prompt, gateway: gateway)) ?? "n/a"
            Log.debug("obtained prompt result")
            self?.isRunning = false
        }
    }
}
