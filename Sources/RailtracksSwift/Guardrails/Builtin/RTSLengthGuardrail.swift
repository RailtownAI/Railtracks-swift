//
//  RTSLengthGuardrail.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-29.
//

import Foundation

/// Input guardrail that blocks when the combined character count of the inspected
/// input keys exceeds `maxCharacters`. Mirrors the Python `InputLengthGuard`.
public struct RTSLengthInputGuardrail: RTSAgentInputGuardrail {
    public let name: String
    public let keys: [String]
    public let maxCharacters: Int

    public init(
        name: String = "InputLengthGuard",
        keys: [String] = ["prompt"],
        maxCharacters: Int = 4096
    ) {
        self.maxCharacters = maxCharacters
        self.keys = keys
        self.name = name
    }

    public func check(_ input: RTSInput) async throws -> RTSInputGuardrailResult {
        let total = keys.reduce(0) { sum, key in
            if case let .string(s)? = input[key] { return sum + s.count }
            return sum
        }
        let meta: [String: RTSValue] = [
            "total_chars": .number(Double(total)),
            "max_chars": .number(Double(maxCharacters)),
        ]
        guard total <= maxCharacters else {
            return .block(
                "Input length \(total) characters exceeds the maximum of \(maxCharacters).",
                metadata: meta
            )
        }
        return .allow(
            "Input length \(total) chars is within the \(maxCharacters)-char limit.",
            metadata: meta
        )
    }
}

/// Output guardrail that blocks when the combined character count of the inspected
/// output keys exceeds `maxCharacters`. Mirrors the Python `OutputLengthGuard`.
public struct RTSLengthOutputGuardrail: RTSAgentOutputGuardrail {
    public let name: String
    public let keys: [String]
    public let maxCharacters: Int

    public init(
        name: String = "OutputLengthGuard",
        keys: [String] = ["result"],
        maxCharacters: Int = 2048
    ) {
        self.maxCharacters = maxCharacters
        self.keys = keys
        self.name = name
    }

    public func check(_ output: RTSOutput) async throws -> RTSOutputGuardrailResult {
        let total = keys.reduce(0) { sum, key in
            if case let .string(s)? = output[key] { return sum + s.count }
            return sum
        }
        let meta: [String: RTSValue] = [
            "total_chars": .number(Double(total)),
            "max_chars": .number(Double(maxCharacters)),
        ]
        guard total <= maxCharacters else {
            return .block(
                "Output length \(total) characters exceeds the maximum of \(maxCharacters).",
                metadata: meta
            )
        }
        return .allow(
            "Output length \(total) chars is within the \(maxCharacters)-char limit.",
            metadata: meta
        )
    }
}
