//
//  MathErrorTools.swift
//  RailtracksSwiftDemo
//

import Foundation
import RailtracksSwift
import Logging

struct AdditionErrorTool: RTSToolNode {
    let id = UUID()
    let toolName = "Addition"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(left) = inputs["a"] else { throw RTSError.missingInput("a") }
        guard case let .number(right) = inputs["b"] else { throw RTSError.missingInput("b") }
        Log.debug("🔢+ Addition tool used!!!")
        return ["result": .number(left + right)]
    }
    var toolDescription = "Adds two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "a", description: "First number to add", type: .number),
            .init(name: "b", description: "Second number to add", type: .number)
        ])
    }
}

struct MultiplicationErrorTool: RTSToolNode {
    let id = UUID()
    let toolName = "Multiplication"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(left) = inputs["a"] else { throw RTSError.missingInput("a") }
        guard case let .number(right) = inputs["b"] else { throw RTSError.missingInput("b") }
        Log.debug("🔢* Multiplication tool used!!!")
        return ["result": .number(left * right)]
    }
    var toolDescription = "Multiplies two numbers and returns the result."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "a", description: "First number to multiply", type: .number),
            .init(name: "b", description: "Second number to multiply", type: .number)
        ])
    }
}

/// Always throws on divide-by-zero to exercise error edge recording in the JSON trace.
struct DivisionErrorTool: RTSToolNode {
    let id = UUID()
    let toolName = "Division"
    var inputs: RTSInput = [:]
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(left) = inputs["a"] else { throw RTSError.missingInput("a") }
        guard case let .number(right) = inputs["b"] else { throw RTSError.missingInput("b") }
        guard right != 0 else {
            throw RTSError.invalidInvocation("Division by zero")
        }
        Log.debug("🔢/ Division tool used!!!")
        return ["result": .number(left / right)]
    }
    var toolDescription = "Divides two numbers and returns the result. Throws if the divisor is zero."
    var parameterSchema: RTSToolSchema {
        RTSToolSchema(parameters: [
            .init(name: "a", description: "Dividend", type: .number),
            .init(name: "b", description: "Divisor", type: .number)
        ])
    }
}

/// Orchestrator that always throws — a deterministic way to drive `flow.run` down its error
/// path (no LLM/tool behavior involved). Used by the demo to confirm a failed run still
/// writes its JSON trace ("trace-ready-on-return" holds even when `run` throws).
struct ThrowingWorkflow: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName = "Throwing Workflow"

    struct DemoError: Error, CustomStringConvertible {
        var description: String { "Intentional demo failure" }
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        throw DemoError()
    }
}
