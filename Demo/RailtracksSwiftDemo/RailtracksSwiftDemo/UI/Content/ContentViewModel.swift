//
//  ContentViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import Logging
import RailtracksSwift

@Observable
class ContentViewModel {
    var libVersion: String = RailtracksSwift.version
    var prompt: String = "What is 50 + 20 x 7? Just give me the final answer"
    var promptResult: String?
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
    
    func startPrompt() {
        Task { [weak self] in
            var logger = Logger(label: "railtracks-swift-demo")
            logger.logLevel = .debug
            
            guard let apiKey = RailtracksSwift.getOpenAIAPIKey() else {
                logger.debug("No API key found")
                return
            }
            let gateway = RTSLLMGateway(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                apiKey: apiKey
            )
            
            do {
                guard let session = try gateway?.session() else {
                    logger.debug("Unable to create session with \(gateway?.modelDescription ?? "--") gateway")
                    return
                }
                let agent = RTAgent(
                    llm: session,
                    systemMessage: "You a helpful assistant that calculate simple math problem asked by user."
                )
                
                let main: ((String) async -> String) = { prompt in
                    (try? await agent.run(prompt)) ?? "No response"
                }
                
                logger.debug("starting prompt, waiting for response...")
                
                self?.promptResult = await main(self?.prompt ?? "")
                logger.debug("obtained prompt result")
            } catch {
                logger.error("Prompt agent error: \(error)")
            }
        }
    }
}
