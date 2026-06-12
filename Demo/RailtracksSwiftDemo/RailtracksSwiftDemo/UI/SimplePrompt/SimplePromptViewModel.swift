//
//  SimplePromptViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation
import RailtracksSwift
import Logging

/// A simple example to demostrate usage of a single Agent with input prompt, and display on screen the obtained output from llm
@Observable
class SimplePromptViewModel {
    let prompt: String = "What is 50 + 20 x 7? Just give me the final answer"
    var promptResult: String?
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
            defer { self?.isRunning = false }
            let gateway = RTSLLMGateway(apiKeys: [.openAI: apiKey])
            let flow = RTSFlow(title: "Simple prompt flow")
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                systemMessage: "You are a helpful assistant that calculate simple math problem asked by user."
            )
            Log.debug("starting prompt, waiting for response...")
            self?.promptResult = try? await flow.run(agent: agent, prompt: prompt, gateway: gateway)
            Log.debug("obtained prompt result")
        }
    }
}
