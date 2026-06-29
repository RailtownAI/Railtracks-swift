//
//  RTSBlockTextGuardrail.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-29.
//

import Foundation

/// Input guardrail that blocks the run when any inspected input value matches a
/// regular expression. Mirrors the Python `BlockTextInputGuard`.
///
/// Patterns use ICU regular-expression syntax (`NSRegularExpression`). The pattern
/// is validated at init (throws on an invalid regex) and compiled per `check`.
public struct RTSBlockTextInputGuardrail: RTSAgentInputGuardrail {
    public let name: String
    public let keys: [String]
    public let pattern: String
    public let blockReason: String

    /// - Throws: if `pattern` is not a valid regular expression.
    public init(
        name: String = "BlockTextInputGuard",
        keys: [String] = ["prompt"],
        pattern: String,
        blockReason: String = "Input blocked: prohibited content detected."
    ) throws {
        _ = try NSRegularExpression(pattern: pattern)
        self.pattern = pattern
        self.keys = keys
        self.blockReason = blockReason
        self.name = name
    }

    public func check(_ input: RTSInput) async throws -> RTSInputGuardrailResult {
        let regex = try NSRegularExpression(pattern: pattern)
        for key in keys {
            if case let .string(s)? = input[key] {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                if regex.firstMatch(in: s, range: range) != nil {
                    return .block(blockReason)
                }
            }
        }
        return .allow("No blocked patterns detected in input.")
    }
}

/// Output guardrail that blocks the run when any inspected output value matches a
/// regular expression. Mirrors the Python `BlockTextOutputGuard`.
public struct RTSBlockTextOutputGuardrail: RTSAgentOutputGuardrail {
    public let name: String
    public let keys: [String]
    public let pattern: String
    public let blockReason: String

    /// - Throws: if `pattern` is not a valid regular expression.
    public init(
        name: String = "BlockTextOutputGuard",
        keys: [String] = ["result"],
        pattern: String,
        blockReason: String = "Output blocked: prohibited content detected."
    ) throws {
        _ = try NSRegularExpression(pattern: pattern)
        self.pattern = pattern
        self.keys = keys
        self.blockReason = blockReason
        self.name = name
    }

    public func check(_ output: RTSOutput) async throws -> RTSOutputGuardrailResult {
        let regex = try NSRegularExpression(pattern: pattern)
        for key in keys {
            if case let .string(s)? = output[key] {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                if regex.firstMatch(in: s, range: range) != nil {
                    return .block(blockReason)
                }
            }
        }
        return .allow("No blocked patterns detected in output.")
    }
}
