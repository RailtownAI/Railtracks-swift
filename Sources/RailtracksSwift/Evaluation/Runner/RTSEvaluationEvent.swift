//
//  RTSEvaluationEvent.swift
//  RailtracksSwift
//

import Foundation

/// A progress/status event emitted during ingestion and evaluation. Non-blocking: the `*Failed` cases
/// are notifications, not stop signals (evaluation is fail-soft). Consumers receive these off the
/// producer's thread — hop to your own queue (`.receive(on:)`) before touching UI.
public enum RTSEvaluationEvent: Sendable {
    /// Ingestion progress. A file that fails to decode still counts toward `filesCompleted` (so the bar
    /// reaches `totalFiles`) but contributes nothing to `runsProcessed`; an `.ingestFailed` is emitted for it.
    case ingesting(filesCompleted: Int, totalFiles: Int, runsProcessed: Int)
    /// Evaluation progress. `total` = data-point count × evaluator count; `completed` counts each
    /// evaluator finishing a data point (success *or* failure), so the bar always reaches `total`.
    case evaluating(completed: Int, total: Int)
    /// A non-blocking ingestion failure: a trace file couldn't be read/decoded and was skipped.
    case ingestFailed(file: String, message: String)
    /// A non-blocking evaluation failure: an evaluator threw or a judge call failed. `evaluator` is
    /// always known; `agent` is the context when known (nil only if not attributable to one agent).
    case evaluationFailed(evaluator: String, agent: String?, message: String)
    /// Terminal event: the run finished and produced `reportCount` reports.
    case finished(reportCount: Int)
}

/// Passed to `RTSEvaluator.run` so an evaluator can report per-data-point progress and non-blocking
/// failures. `reportProgress` is called once per data point the evaluator finishes; `emit` surfaces
/// events (e.g. `.evaluationFailed`). Both are safe to call from concurrent tasks.
public struct RTSEvaluatorRunContext: Sendable {
    public let reportProgress: @Sendable () -> Void
    public let emit: @Sendable (RTSEvaluationEvent) -> Void

    public init(
        reportProgress: @escaping @Sendable () -> Void,
        emit: @escaping @Sendable (RTSEvaluationEvent) -> Void
    ) {
        self.reportProgress = reportProgress
        self.emit = emit
    }
}
