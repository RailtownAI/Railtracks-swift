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
    let prompt: String = "What is 50 + 20 x 8? Just give me the final answer"
//    let prompt: String = "Are you able to see the addition tool I provided?"
    var promptResult: String?
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
    
    func startPrompt() {
        let prompt = self.prompt
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
                let tools = [AdditionTool()]
                guard let session = gateway?.session(tools: tools) else {
                    logger.debug("Unable to create session with \(gateway?.modelDescription ?? "--") gateway")
                    return
                }
                
                let agent = RTAgent(
                    llm: session,
                    systemMessage: "You are a Math assistant.  If there is addition in the math, you must use the provided addition tool to perfrom the calculation.  You will calculate simple math problem asked by user."
                )
                
//                let additionTool = RTSTool(
//                    name: "Addition",
//                    inputs: ["a": RTSValue.double(3), "b": RTSValue.double(5)]
//                ) { inputDict in
//                    let sum = inputDict.values.reduce(0.0) { acc, val in
//                        guard case .double(let d) = val else { return acc }
//                        return acc + d
//                    }
//                    return ["result": .double(sum)]
//                }
                
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

struct AdditionTool: RTSToolNode {
    let id = UUID()
    let _name = "Addition"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        var logger = Logger(label: "railtracks-swift-demo")
        logger.logLevel = .debug
        let sum = inputs.values.reduce(0.0) { base, val in
            guard case .double(let d) = val else { return base }
            return base + d
        }
        logger.debug("🧮﹢ Addition tool used!!!")
        return ["result": .double(sum)]
    }
//    let closure: @concurrent (RTSInput) async throws -> RTSOutput = { inputs in
//        let sum = inputs.values.reduce(0.0) { acc, val in
//            guard case .double(let d) = val else { return acc }
//            return acc + d
//        }
//        return ["result": .double(sum)]
//    }
    var toolDescription: String = "Adds two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(name: "a", description: "First number to add", type: .double),
                .init(name: "b", description: "Second number to add", type: .double)
            ]
        )
    }

    func run(with a: Double, _ b: Double) async throws -> Double {
        let output = try await run(with: ["a": RTSValue.double(a), "b": RTSValue.double(b)])
        guard case .double(let result) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return result
    }
}
