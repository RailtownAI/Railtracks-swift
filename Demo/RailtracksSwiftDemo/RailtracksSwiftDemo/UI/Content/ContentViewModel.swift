//
//  ContentViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import Logging
import RailtracksSwift
import ConduitAdvanced

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
            
            //TODO: incapsulate Conduit layer usage from user
            guard let apiKey = RailtracksSwift.getOpenAIAPIKey() else {
                logger.debug("No API key found")
                return
            }
            let conduit = Conduit(.openAI(apiKey: apiKey))
            do {
                let agent = RTAgent(
                    // TODO: consider the option to extend or change th lib so Model.init(_ identifier: ModelIdentifier) is public
                    llm: try conduit.session(model: .openAI(OpenAIModelID.gpt4o.rawValue)),
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
