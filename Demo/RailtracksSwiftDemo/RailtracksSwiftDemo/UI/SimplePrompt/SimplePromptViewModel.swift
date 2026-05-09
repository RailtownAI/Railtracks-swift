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
            let session = flow.session(gateway: gateway)
            
            let agent = RTSAgent(
                llm: session,
                systemMessage: "You are a helpful assistant that calculate simple math problem asked by user."
            )
            
            let mainFunction = RTSSimpleFunction(name: "main", prompt: prompt) { prompt in
                (try? await agent.run(prompt)) ?? "No response"
            }
            
            Log.debug("starting prompt, waiting for response...")
            
            self?.promptResult = try? await mainFunction.invokeForStringResponse()
            Log.debug("obtained prompt result")
        }
    }
}
