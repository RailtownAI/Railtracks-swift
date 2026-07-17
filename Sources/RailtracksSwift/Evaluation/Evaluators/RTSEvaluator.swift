//
//  RTSEvaluator.swift
//  RailtracksSwift
//

import Foundation

/// An evaluator consumes all data points for a single agent and produces one evaluator result.
/// `run` is `async` so LLM-backed evaluators (the judge) fit the same shape; the prebuilt
/// evaluators are pure and complete synchronously.
public protocol RTSEvaluator: Sendable {
    /// Display name, used as `evaluator_name` (conventionally the type name).
    var name: String { get }
    /// Deterministic identity hash of the evaluator's config, used as `evaluator_id`.
    var identifier: String { get }

    /// Evaluate `data`. `context` (when provided) lets the evaluator report per-data-point progress
    /// and non-blocking failures; pass nil when progress isn't needed. Evaluators should call
    /// `context?.reportProgress()` once per data point they finish (success or failure).
    func run(
        _ data: [RTSAgentDataPoint],
        context: RTSEvaluatorRunContext?
    ) async throws -> RTSEvaluatorOutput
}

public extension RTSEvaluator {
    /// Convenience for callers that don't need progress reporting.
    func run(_ data: [RTSAgentDataPoint]) async throws -> RTSEvaluatorOutput {
        try await run(data, context: nil)
    }
}

/// An evaluator's output: the serialized report piece plus the metric definitions it used.
/// The metrics feed the report's `metrics_map` and are carried separately because they are not
/// serialized inside `RTSEvaluatorResult` (mirrors Python's `exclude=True` on that field).
public struct RTSEvaluatorOutput: Sendable {
    public let result: RTSEvaluatorResult
    public let metrics: [RTSMetric]

    public init(result: RTSEvaluatorResult, metrics: [RTSMetric]) {
        self.result = result
        self.metrics = metrics
    }
}

// MARK: - Identity helpers

enum RTSEvaluatorIdentity {
    /// Deterministic evaluator id: hash of the type name plus any identity-defining config parts,
    /// joined in a fixed order. Only intra-report consistency matters, so the format is ours.
    static func identifier(typeName: String, config: [String] = []) -> String {
        let material = ([typeName] + config).joined(separator: "|")
        return RailtracksSwift.equalityHash(material)
    }
}
