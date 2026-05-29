//
//  MathTools.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation
import RailtracksSwift
import Logging

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

    /// Function `run` here is not needed in Tool execution flow.  The LLM call to tool does not use it.
    /// This function is mainly here if App side code wants to call the tool directly
    /// or for testing to verify correctness of such tool.
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
    var toolDescription: String = "Subtracts two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(name: "a", description: "First number as minuend in subtraction", type: .number),
                .init(name: "b", description: "Second number as subtrahend in subtraction", type: .number)
            ]
        )
    }
    
    /// Function `run` here is not needed in Tool execution flow.  The LLM call to tool does not use it.
    /// This function is mainly here if App side code wants to call the tool directly
    /// or for testing to verify correctness of such tool.
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
    
    /// Function `run` here is not needed in Tool execution flow.  The LLM call to tool does not use it.
    /// This function is mainly here if App side code wants to call the tool directly
    /// or for testing to verify correctness of such tool.
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
        guard right != 0 else {
            return ["result": .number(.nan)]
        }
        let result = left / right
        Log.debug("🔢/ Division tool used!!!")
        return ["result": .number(result)]
    }
    var toolDescription: String = "Divides two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(name: "a", description: "First number as the dividend in division", type: .number),
                .init(name: "b", description: "Second number as the divisor in division", type: .number)
            ]
        )
    }
    
    /// Function `run` here is not needed in Tool execution flow.  The LLM call to tool does not use it.
    /// This function is mainly here if App side code wants to call the tool directly
    /// or for testing to verify correctness of such tool.
    func run(with a: Double, _ b: Double) async throws -> Double {
        let output = try await run(with: ["a": RTSValue.number(a), "b": RTSValue.number(b)])
        guard case .number(let result) = output["result"] else {
            throw RTSError.missingOutput("result")
        }
        return result
    }
}
