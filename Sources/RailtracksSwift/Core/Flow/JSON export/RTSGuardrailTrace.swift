//
//  RTSGuardrailTrace.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-26.
//

import Foundation

/// One guardrail step recorded during a run, serialized into
/// `node.details.internals.guard_details`.
///
/// Mirrors the Python visualizer's `GuardrailTrace` model field-for-field.
public struct RTSGuardrailTrace: Codable, Sendable {

    /// Trace action label.
    public enum Action: String, Sendable {
        case allow
        case transform
        case block
        /// The runner caught an exception from the guardrail's `check`.
        case error
    }

    /// The guardrail's `name`.
    public let railName: String
    /// `"llm_input"` or `"llm_output"`.
    public let phase: String
    /// `"allow"`, `"transform"`, `"block"`, or `"error"`.
    public let action: String
    /// Short human-readable explanation, or a fixed message for error traces.
    public let reason: String
    /// Optional, freeform supplementary data the guardrail author deemed relevant
    /// to this step. Serialized verbatim; carries no required structure.
    public let metadata: [String: RTSValue]?

    enum CodingKeys: String, CodingKey {
        case railName = "rail_name"
        case phase
        case action
        case reason
        case metadata = "meta"
    }

    init(
        railName: String,
        stage: RTSGuardrailStage,
        action: Action,
        reason: String,
        metadata: [String: RTSValue]?
    ) {
        self.railName = railName
        self.phase = stage.phaseValue
        self.action = action.rawValue
        self.reason = reason
        self.metadata = metadata
    }

    /// Builds an `error`-action trace for a guardrail that raised an exception,
    /// mirroring the Python runner's exception metadata.
    static func error(
        railName: String,
        stage: RTSGuardrailStage,
        error: Error
    ) -> RTSGuardrailTrace {
        RTSGuardrailTrace(
            railName: railName,
            stage: stage,
            action: .error,
            reason: "Guardrail raised exception",
            metadata: [
                "exception_type": .string(String(describing: type(of: error))),
                "exception_message": .string("\(error)")
            ]
        )
    }
}
