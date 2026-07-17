//
//  RTSEvaluationManager.swift
//  RailtracksSwift
//

import Foundation
import Combine

/// Object-based entry point spanning ingestion + evaluation, publishing a single progress feed.
/// Subscribe `progressPublisher` **before** calling `run`. Convenience over the static
/// `RTSEvaluationIngest` / `RTSEvaluation.evaluate` APIs — use those directly if you don't want progress.
///
/// Events are serialized (a lock) and selectively throttled: `.ingesting`/`.evaluating` coalesce to at
/// most one per 0.1s so the UI isn't flooded, while `.failed` and `.finished` pass through immediately
/// (failures are never dropped; completion always arrives). Events are delivered off the producer's
/// thread — `.receive(on:)` before touching UI.
public final class RTSEvaluationManager: @unchecked Sendable {
    private let subject = PassthroughSubject<RTSEvaluationEvent, Never>()
    private let lock = NSLock()
    private var lastProgressSend: UInt64 = 0
    private let minProgressIntervalNanos: UInt64 = 100_000_000   // 0.1s

    public init() {}

    public var progressPublisher: AnyPublisher<RTSEvaluationEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Ingest `files`, then evaluate with `evaluators`, publishing progress throughout and `.finished`
    /// at the end. Parameters mirror `RTSEvaluation.evaluate`.
    public func run(
        fromFiles files: [URL],
        evaluators: [any RTSEvaluator],
        agents: [String]? = nil,
        name: String? = nil,
        limits: RTSConcurrencyLimits? = nil,
        persist: Bool = true
    ) async -> [RTSEvaluationReport] {
        let emit: @Sendable (RTSEvaluationEvent) -> Void = { [weak self] event in
            self?.send(event)
        }
        let data = RTSEvaluationIngest.agentDataPoints(fromFiles: files, onEvent: emit)
        let reports = await RTSEvaluation.evaluate(
            data: data,
            evaluators: evaluators,
            agents: agents,
            name: name,
            limits: limits,
            persist: persist,
            onEvent: emit
        )
        send(.finished(reportCount: reports.count))
        return reports
    }

    /// Serialized, selectively-throttled publish. Progress events coalesce to ≤1 per interval (dropping
    /// intermediate values is fine — progress is monotonic, and `.finished` always follows); `.failed`
    /// and `.finished` are never throttled.
    private func send(_ event: RTSEvaluationEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .ingesting, .evaluating:
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastProgressSend >= minProgressIntervalNanos {
                lastProgressSend = now
                subject.send(event)
            }
        case .ingestFailed, .evaluationFailed, .finished:
            subject.send(event)
        }
    }
}
