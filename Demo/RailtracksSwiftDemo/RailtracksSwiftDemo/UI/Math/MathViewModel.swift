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
    let prompt: String = "What is 50 + 20 x 8 - 4? Give me the final answer in a single number without any description."
    var promptResult: String?
    
    var openAIAPIKey: String? {
        RailtracksSwift.getOpenAIAPIKey()
    }
    
    func startPrompt() {
        let prompt = self.prompt
        Task { [weak self] in
            guard let apiKey = RailtracksSwift.getOpenAIAPIKey() else {
                Log.debug("No API key found")
                return
            }
            let gateway = RTSLLMGateway(
                llmProvider: .openAI(modelIDString: RTSOpenAIModelID.gpt4o.modelIDString),
                apiKey: apiKey
            )
            
            let tools: [any RTSToolNode] = [
                AdditionTool(),
                SubtractionTool(),
                MultiplicationTool(),
                DivisionTool()
            ]
            guard let session = gateway?.session(tools: tools) else {
                Log.debug("Unable to create session with \(gateway?.modelDescription ?? "--") gateway")
                return
            }
            
            let agent = RTAgent(
                llm: session,
                systemMessage: "You are a Math assistant. " +
                "If there is addition in the math, you must use the provided addition tool to perform the calculation. " +
                "If there is subtraction in the math, you must use the provided subtraction tool to perform the calculation. " +
                "If there is multiplication in the math, you must use the provided multiplication tool to perform the calculation. " +
                "If there is division in the math, you must use the provided division tool to perfrom the calculation. " +
                "You will calculate simple math problem asked by user."
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

struct AdditionTool: RTSToolNode {
    let id = UUID()
    let toolName = "Addition"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(left) = inputs["a"] else {
            throw RTSError.missingInput("a")
        }
        guard case let .number(right) = inputs["b"] else {
            throw RTSError.missingInput("b")
        }
        let sum = left + right
        Log.debug("🔢+ Addition tool used!!!")
        return ["result": .number(sum)]
    }
    var toolDescription: String = "Adds two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(name: "a", description: "First number to add", type: .number),
                .init(name: "b", description: "Second number to add", type: .number)
            ]
        )
    }

    func run(with a: Double, _ b: Double) async throws -> Double {
        let output = try await run(with: ["a": RTSValue.number(a), "b": RTSValue.number(b)])
        guard case .number(let result) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return result
    }
}

struct SubtractionTool: RTSToolNode {
    let id = UUID()
    let toolName = "Subtraction"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(minuend) = inputs["a"] else {
            throw RTSError.missingInput("a")
        }
        guard case let .number(subtrahend) = inputs["b"] else {
            throw RTSError.missingInput("b")
        }
        let result = minuend - subtrahend
        Log.debug("🔢- Subtraction tool used!!!")
        return ["result": .number(result)]
    }
    var toolDescription: String = "Subtract two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(name: "a", description: "First number as minuend in subtraction", type: .number),
                .init(name: "b", description: "Second number as subtrahend in subtraction", type: .number)
            ]
        )
    }
    
    func run(with a: Double, _ b: Double) async throws -> Double {
        let output = try await run(with: ["a": RTSValue.number(a), "b": RTSValue.number(b)])
        guard case .number(let result) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return result
    }
}

struct MultiplicationTool: RTSToolNode {
    let id = UUID()
    let toolName = "Multiplication"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(left) = inputs["a"] else {
            throw RTSError.missingInput("a")
        }
        guard case let .number(right) = inputs["b"] else {
            throw RTSError.missingInput("b")
        }
        let result = left * right
        Log.debug("🔢* Multiplication tool used!!!")
        return ["result": .number(result)]
    }
    var toolDescription: String = "Multiplies two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(name: "a", description: "First number to multiply", type: .number),
                .init(name: "b", description: "Second number to multiply", type: .number)
            ]
        )
    }
    
    func run(with a: Double, _ b: Double) async throws -> Double {
        let output = try await run(with: ["a": RTSValue.number(a), "b": RTSValue.number(b)])
        guard case .number(let result) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return result
    }
}

struct DivisionTool: RTSToolNode {
    let id = UUID()
    let toolName = "Division"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(left) = inputs["a"] else {
            throw RTSError.missingInput("a")
        }
        guard case let .number(right) = inputs["b"] else {
            throw RTSError.missingInput("b")
        }
        let result = left / right
        Log.debug("🔢/ Division tool used!!!")
        return ["result": .number(result)]
    }
    var toolDescription: String = "Divides two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(name: "a", description: "First number as the divident in division", type: .number),
                .init(name: "b", description: "Second number as the divisor in division", type: .number)
            ]
        )
    }
    
    func run(with a: Double, _ b: Double) async throws -> Double {
        let output = try await run(with: ["a": RTSValue.number(a), "b": RTSValue.number(b)])
        guard case .number(let result) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return result
    }
}
