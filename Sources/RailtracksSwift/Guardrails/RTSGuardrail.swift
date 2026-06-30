//
//  RTSGuardrail.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-26.
//

import Foundation

/// Which side of an agent's LLM call a guardrail observes.
///
/// Maps to the trace `phase` string consumed by the visualizer:
/// `.input` → `"llm_input"`, `.output` → `"llm_output"`.
public enum RTSGuardrailStage: Sendable, Equatable {
    case input
    case output

    var phaseValue: String {
        switch self {
        case .input:  
            return "llm_input"
        case .output: 
            return "llm_output"
        }
    }
}

// MARK: - Results

/// Outcome of an input guardrail.
///
/// Prefer the `.allow` / `.block` / `.transform` factories for terse call sites.
/// The `reason` and `metadata` on each case are recorded in the run's guardrail
/// trace; see `metadata` guidance on the factories below.
public enum RTSInputGuardrailResult: Sendable {
    /// Let the input through unchanged.
    case allowed(
        reason: String,
        metadata: [String: RTSValue]?
    )
    /// Block the run. The agent's LLM is never called and `flow.run` throws
    /// `RTSError.guardrailBlocked`.
    case blocked(
        reason: String,
        metadata: [String: RTSValue]?
    )
    /// Replace the input; the chain continues with the new value.
    case transformed(
        RTSInput,
        reason: String,
        metadata: [String: RTSValue]?
    )
}

public extension RTSInputGuardrailResult {
    /// Allow the input through unchanged.
    /// - Parameters:
    ///   - reason: Short human-readable explanation, recorded in the trace.
    ///   - metadata: Optional, freeform supplementary data the guardrail author
    ///     deems relevant to this step (measured values, thresholds, counts, …).
    ///     Serialized verbatim into the trace's `meta` field; it carries no
    ///     required structure. Leave `nil` when `reason` alone is sufficient.
    static func allow(
        _ reason: String = "",
        metadata: [String: RTSValue]? = nil
    ) -> Self {
        .allowed(reason: reason, metadata: metadata)
    }
    /// Block the run with a reason.
    /// - Parameters:
    ///   - reason: Why the input was blocked, recorded in the trace and carried
    ///     on the thrown `RTSError.guardrailBlocked`.
    ///   - metadata: Optional freeform detail; see `allow(_:metadata:)`.
    static func block(
        _ reason: String,
        metadata: [String: RTSValue]? = nil
    ) -> Self {
        .blocked(reason: reason, metadata: metadata)
    }
    /// Replace the input and continue the chain.
    /// - Parameters:
    ///   - input: The rewritten input passed to the next guardrail (or the LLM).
    ///   - reason: What was changed, recorded in the trace.
    ///   - metadata: Optional freeform detail; see `allow(_:metadata:)`.
    static func transform(
        _ input: RTSInput,
        reason: String = "",
        metadata: [String: RTSValue]? = nil
    ) -> Self {
        .transformed(input, reason: reason, metadata: metadata)
    }
}

/// Outcome of an output guardrail. Mirrors `RTSInputGuardrailResult`, but
/// `.transform` carries a replacement `RTSOutput`.
public enum RTSOutputGuardrailResult: Sendable {
    /// Let the output through unchanged.
    case allowed(
        reason: String,
        metadata: [String: RTSValue]?
    )
    /// Block the result and `flow.run` throws `RTSError.guardrailBlocked`.
    case blocked(
        reason: String,
        metadata: [String: RTSValue]?
    )
    /// Replace the output; the chain continues with the new value.
    case transformed(
        RTSOutput,
        reason: String,
        metadata: [String: RTSValue]?
    )
}

public extension RTSOutputGuardrailResult {
    /// Allow the output through unchanged. See `RTSInputGuardrailResult.allow(_:metadata:)`
    /// for the `metadata` contract.
    static func allow(
        _ reason: String = "",
        metadata: [String: RTSValue]? = nil
    ) -> Self {
        .allowed(reason: reason, metadata: metadata)
    }
    /// Block the run with a reason.
    static func block(
        _ reason: String,
        metadata: [String: RTSValue]? = nil
    ) -> Self {
        .blocked(reason: reason, metadata: metadata)
    }
    /// Replace the output and continue the chain.
    static func transform(
        _ output: RTSOutput,
        reason: String = "",
        metadata: [String: RTSValue]? = nil
    ) -> Self {
        .transformed(output, reason: reason, metadata: metadata)
    }
}

// MARK: - Protocols

/// A guardrail that runs before an agent's input reaches the LLM.
///
/// An agent's `inputGuardrails` run in array order. A `.transformed` result feeds
/// the next guardrail; the first `.blocked` short-circuits the rest and fails the
/// run with `RTSError.guardrailBlocked`. If `check` throws, the run fails with the
/// thrown error (recorded in the trace as an `error` step).
public protocol RTSAgentInputGuardrail: Sendable {
    /// Recorded as `rail_name` in the trace. Defaults to the conforming type's name.
    var name: String { get }
    func check(_ input: RTSInput) async throws -> RTSInputGuardrailResult
}

public extension RTSAgentInputGuardrail {
    var name: String { String(describing: type(of: self)) }
}

/// A guardrail that runs after an agent's LLM output, before it is returned to the caller.
public protocol RTSAgentOutputGuardrail: Sendable {
    /// Recorded as `rail_name` in the trace. Defaults to the conforming type's name.
    var name: String { get }
    func check(_ output: RTSOutput) async throws -> RTSOutputGuardrailResult
}

public extension RTSAgentOutputGuardrail {
    var name: String { String(describing: type(of: self)) }
}

// MARK: - Closure conformers

/// Closure-backed input guardrail for inline, stateless checks.
public struct RTSClosureInputGuardrail: RTSAgentInputGuardrail {
    public let name: String
    private let closure: @Sendable (RTSInput) async throws -> RTSInputGuardrailResult

    public init(
        name: String,
        _ closure: @escaping @Sendable (RTSInput) async throws -> RTSInputGuardrailResult
    ) {
        self.name = name
        self.closure = closure
    }

    public func check(
        _ input: RTSInput
    ) async throws -> RTSInputGuardrailResult {
        try await closure(input)
    }
}

/// Closure-backed output guardrail for inline, stateless checks.
public struct RTSClosureOutputGuardrail: RTSAgentOutputGuardrail {
    public let name: String
    private let closure: @Sendable (RTSOutput) async throws -> RTSOutputGuardrailResult

    public init(
        name: String,
        _ closure: @escaping @Sendable (RTSOutput) async throws -> RTSOutputGuardrailResult
    ) {
        self.name = name
        self.closure = closure
    }

    public func check(
        _ output: RTSOutput
    ) async throws -> RTSOutputGuardrailResult {
        try await closure(output)
    }
}
