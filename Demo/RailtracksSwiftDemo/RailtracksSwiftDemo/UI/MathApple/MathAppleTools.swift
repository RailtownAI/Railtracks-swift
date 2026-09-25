//
//  MathAppleTools.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation
import RailtracksSwift
import FoundationModels
import Logging

/// The prompt and system message shared by the tool-using math demos (AppleAI and Claude), so each
/// demo sends identical text and their traces compare like for like.
enum MathToolsPrompt {
    static let prompt = "What is 50 + 20 x 8 - 4? Give me the final answer in a single number without any description."
    static let systemMessage = "You are a Math assistant. " +
        "If there is addition in the math, you must use the provided addition tool to perform the calculation. " +
        "If there is subtraction in the math, you must use the provided subtraction tool to perform the calculation. " +
        "If there is multiplication in the math, you must use the provided multiplication tool to perform the calculation. " +
        "If there is division in the math, you must use the provided division tool to perform the calculation. " +
        "You will use the tools in proper sequence and wait for result of multiplication and division tools before using addition and subtraction tools." +
        "You must use these tools one at a time and not run them in parallel." +
        "You will calculate simple math problem asked by user."
}

@available(macOS 26, iOS 26, *)
struct AdditionToolApple: RTSAppleAIToolNode {
    typealias Output = String

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
        Log.debug("🔢+ Addition tool used!!!")
        return ["result": .number(left + right)]
    }
    var toolDescription: String = "Adds two numbers and returns the result."

    // parameterSchema derived from @Guide descriptions below
    @Generable struct Arguments: Encodable {
        @Guide(description: "First number to add")
        var a: Double
        @Guide(description: "Second number to add")
        var b: Double
    }

    // call(arguments:) bridged to callableRoutine automatically
}

@available(macOS 26, iOS 26, *)
struct SubtractionToolApple: RTSAppleAIToolNode {
    typealias Output = String

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
        Log.debug("🔢- Subtraction tool used!!!")
        return ["result": .number(minuend - subtrahend)]
    }
    var toolDescription: String = "Subtracts two numbers and returns the result."

    @Generable struct Arguments: Encodable {
        @Guide(description: "First number as minuend in subtraction")
        var a: Double
        @Guide(description: "Second number as subtrahend in subtraction")
        var b: Double
    }
}

@available(macOS 26, iOS 26, *)
struct MultiplicationToolApple: RTSAppleAIToolNode {
    typealias Output = String

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
        Log.debug("🔢* Multiplication tool used!!!")
        return ["result": .number(left * right)]
    }
    var toolDescription: String = "Multiplies two numbers and returns the result."

    @Generable struct Arguments: Encodable {
        @Guide(description: "First number to multiply")
        var a: Double
        @Guide(description: "Second number to multiply")
        var b: Double
    }
}

@available(macOS 26, iOS 26, *)
struct DivisionToolApple: RTSAppleAIToolNode {
    typealias Output = String

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
        guard right != 0 else { return ["result": .number(.nan)] }
        Log.debug("🔢/ Division tool used!!!")
        return ["result": .number(left / right)]
    }
    var toolDescription: String = "Divides two numbers and returns the result."

    @Generable struct Arguments: Encodable {
        @Guide(description: "First number as the dividend in division")
        var a: Double
        @Guide(description: "Second number as the divisor in division")
        var b: Double
    }
}
