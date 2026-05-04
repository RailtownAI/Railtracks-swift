//
//  MathViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation
import RailtracksSwift
import Logging

@Observable
class MathViewModel {
    var prompt: String = "What is 50 + 20 x 8? Just give me the final answer"
    var promptResult: String?
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
    
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
                
                let additionTool = RTSTool(
                    name: "Addition",
                    inputs: ["a": RTSValue.double(3), "b": RTSValue.double(5)]
                ) { inputDict in
                    let sum = inputDict.values.reduce(0.0) { acc, val in
                        guard case .double(let d) = val else { return acc }
                        return acc + d
                    }
                    return ["result": .double(sum)]
                }
                
                let mainFunction = RTSSimpleFunction(name: "main", prompt: prompt) { prompt in
                    (try? await agent.run(prompt)) ?? "No response"
                }
                
                logger.debug("starting prompt, waiting for response...")
                
                self?.promptResult = try? await mainFunction.invokeForStringResponse()
                logger.debug("obtained prompt result")
            } catch {
                logger.error("Prompt agent error: \(error)")
            }
        }
    }
}
