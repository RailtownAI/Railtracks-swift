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

enum RTSError: Error {
    case missingInput(String)
    case missingOutput(String)
}

struct RTSSimpleFunction: RTSFunctionNode {
    enum CodingKeys: CodingKey {
        case id
        case name
    }
    
    let id = UUID()
    let _name: String
    let inputs: RTSInput
    let callableRoutine: @concurrent (RTSInput) async throws -> RTSOutput
    
    init(name: String, prompt: String, routine: @escaping (String) async throws -> String) {
        self._name = name
        self.inputs = ["prompt": .string(prompt)]
        self.callableRoutine = { inputs in
            guard case .string(let requestString) = inputs["prompt"] else {
                throw RTSError.missingInput("prompt")
            }
            let result = try await routine(requestString)
            return ["result": .string(result)]
        }
    }
    
    // terminal call function to unwrap Output from RTSNode.invoke()
    func invokeForStringResponse() async throws -> String {
        let output = try await invoke()
        guard case .string(let responseString) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return responseString
    }
    
    func name() -> String {
        return _name
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(_name, forKey: .name)
    }
}
