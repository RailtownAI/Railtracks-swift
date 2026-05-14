//
//  SimplePromptViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation
import RailtracksSwift
import Logging

@Observable
class SimplePromptViewModel {
    let prompt: String = "What is 50 + 20 x 7? Just give me the final answer"
    var promptResult: String?
    
    
    func startPrompt() {
        let prompt = self.prompt
        Task { [weak self] in
            guard let apiKey = RailtracksSwift.getOpenAIAPIKey() else {
                Log.error("No API key found")
                return
            }
            guard let gateway = RTSLLMGateway(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                apiKey: apiKey
            ) else {
                Log.error("Cannot establish LLM gateway")
                return
            }
            
            let flow = RTSFlow(title: "Simple prompt flow") { _ in
                ""
            }

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
