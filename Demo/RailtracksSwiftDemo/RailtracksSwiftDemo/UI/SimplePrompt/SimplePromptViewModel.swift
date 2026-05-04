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
    var prompt: String = "What is 50 + 20 x 7? Just give me the final answer"
    var promptResult: String?
    
    
    func startPrompt() {
        let prompt = prompt
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
                
//                let main: (String) async -> String = { prompt in
//                    // TODO: in python source, instead of triggering Node.invoke,
//                    // it trigger a high level call rt.call and give it node and argument
//                    // is it so that argument type and volume are earased?
//                    (try? await agent.run(prompt)) ?? "No response"
//                }
                let mainFunction = RTSSimpleFunction(name: "main", prompt: prompt) { prompt in
                    (try? await agent.run(prompt)) ?? "No response"
                }
                
                logger.debug("starting prompt, waiting for response...")
                
//                self?.promptResult = await main(self?.prompt ?? "")
                self?.promptResult = try? await mainFunction.invokeForStringResponse()
                logger.debug("obtained prompt result")
            } catch {
                logger.error("Prompt agent error: \(error)")
            }
        }
    }
}
