//
//  RTSGuardrailDecision.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSGuardrailDecision

/// The verdict one guardrail returned, as carried on a `middleware.guard.*.response` event.
///
/// Mirrors the Python engine's `GuardrailDecision` (`guardrails/core/decision.py`), which
/// fills the `decision` JSON column. Python splits the replacement value across two fields
/// — `messages` for the input phase, `output_message` for the output phase — where this
/// carries a single ``transformedValue``, because Swift's guardrails operate on
/// `RTSInput` / `RTSOutput` rather than on a message history. Swift has no equivalent of
/// Python's `user_facing_message`.
///
/// Distinct from ``RTSGuardrailTrace``, which flattens the same verdict for the flow
/// graph's `node.details.internals.guard_details`. The duplication is deliberate: the two
/// output streams are independent, and the trace's field names are frozen by the
/// visualizer's schema.
public struct RTSGuardrailDecision: Sendable, Equatable {

    /// What the runner should do after the guardrail returns.
    ///
    /// Mirrors Python's `GuardrailAction`.
    public enum Action: String, Sendable, Codable {
        case allow
        case transform
        case block
    }

    public let action: Action
    public let reason: String
    /// The replacement input or output on a ``Action/transform``; `nil` otherwise.
    public let transformedValue: RTSValue?
    /// Freeform supplementary data the guardrail author attached.
    public let metadata: [String: RTSValue]?

    public init(
        action: Action,
        reason: String,
        transformedValue: RTSValue? = nil,
        metadata: [String: RTSValue]? = nil
    ) {
        self.action = action
        self.reason = reason
        self.transformedValue = transformedValue
        self.metadata = metadata
    }

    /// The `decision` payload value.
    ///
    /// Every key is written, `null` included, matching Python's encoding.
    func encoded() -> RTSValue {
        .object([
            "action": .string(action.rawValue),
            "reason": .string(reason),
            "transformed_value": .nullable(transformedValue),
            "meta": metadata.map { RTSValue.object($0) } ?? .null,
        ])
    }
}

// MARK: - Building from guardrail results

extension RTSGuardrailDecision {

    /// The decision an input guardrail returned.
    public init(_ result: RTSInputGuardrailResult) {
        switch result {
        case .allowed(let reason, let metadata):
            self.init(
                action: .allow,
                reason: reason,
                metadata: metadata
            )
        case .transformed(let newInput, let reason, let metadata):
            self.init(
                action: .transform,
                reason: reason,
                transformedValue: .object(newInput),
                metadata: metadata
            )
        case .blocked(let reason, let metadata):
            self.init(
                action: .block,
                reason: reason,
                metadata: metadata
            )
        }
    }

    /// The decision an output guardrail returned.
    public init(_ result: RTSOutputGuardrailResult) {
        switch result {
        case .allowed(let reason, let metadata):
            self.init(
                action: .allow,
                reason: reason,
                metadata: metadata
            )
        case .transformed(let newOutput, let reason, let metadata):
            self.init(
                action: .transform,
                reason: reason,
                transformedValue: .object(newOutput),
                metadata: metadata
            )
        case .blocked(let reason, let metadata):
            self.init(
                action: .block,
                reason: reason,
                metadata: metadata
            )
        }
    }
}
