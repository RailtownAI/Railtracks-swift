//
//  EvaluationJudgeTests.swift
//  RailtracksSwiftTests
//
//  Phase 3: the LLM judge evaluator + the concurrency limiter. The judge is driven by a stubbed
//  RTSJudgeCall so the aggregation logic is verified deterministically with no live LLM.
//

import Testing
import Foundation
import Combine
@testable import RailtracksSwift

/// A stub `RTSJudgeCall` source: pops canned responses in call order (cycling if exhausted). Order is
/// irrelevant to the count/aggregate assertions — only the multiset of returned labels matters.
private actor StubJudge {
    private let responses: [RTSJudgeResponse]
    private var index = 0

    init(_ responses: [RTSJudgeResponse]) {
        self.responses = responses
    }

    func next() -> RTSJudgeResponse {
        let response = responses[index % responses.count]
        index += 1
        return response
    }
}

/// Tracks peak concurrency for the limiter test.
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var maxConcurrent = 0

    func enter() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func exit() {
        current -= 1
    }
}

/// Thread-safe collector for progress events emitted from concurrent tasks.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RTSEvaluationEvent] = []

    func add(_ event: RTSEvaluationEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [RTSEvaluationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@Suite("Evaluation — Phase 3 (judge + limiter)")
struct EvaluationJudgeTests {

    // MARK: - Builders

    private func dataPoint(agent: String = "TestAgent") -> RTSAgentDataPoint {
        RTSAgentDataPoint(
            id: UUID(),
            sessionID: UUID(),
            agentName: agent,
            agentInput: .string("input"),
            agentOutput: .object(["message_history": .string("output")]),
            llmCalls: [],
            toolNames: [],
            toolCalls: []
        )
    }

    private func judge(
        metrics: [RTSCategoricalMetric],
        reasoning: Bool,
        stub: StubJudge
    ) -> RTSJudgeEvaluator {
        RTSJudgeEvaluator(
            provider: .appleAI,
            metrics: metrics,
            includesReasoning: reasoning,
            limiter: RTSConcurrencyLimiter(limit: nil),   // unbounded, no shared-registry state
            judgeCall: { _, _ in await stub.next() }
        )
    }

    private func baseLeaves(_ output: RTSEvaluatorOutput) -> [RTSBaseMetricResult] {
        output.result.metricResults.compactMap { result in
            guard case .base(let leaf) = result else { return nil }
            return leaf
        }
    }

    private func categoricalAggregates(_ output: RTSEvaluatorOutput) -> [RTSCategoricalAggregate] {
        output.result.aggregateResults.nodes.values.compactMap { node in
            guard case .categoricalAggregate(let aggregate) = node else { return nil }
            return aggregate
        }
    }

    // MARK: - Aggregation

    @Test("judge: one categorical aggregate per metric with correct counts + extremes")
    func judgeCounts() async throws {
        let metric = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let stub = StubJudge([
            RTSJudgeResponse(metricValue: "good", reasoning: "r"),
            RTSJudgeResponse(metricValue: "good", reasoning: "r"),
            RTSJudgeResponse(metricValue: "bad", reasoning: "r"),
        ])
        let output = try await judge(metrics: [metric], reasoning: true, stub: stub)
            .run([dataPoint(), dataPoint(), dataPoint()])

        let aggregates = categoricalAggregates(output)
        #expect(aggregates.count == 1)
        let aggregate = try #require(aggregates.first)
        #expect(aggregate.name == "Aggregate/Helpfulness")
        #expect(aggregate.children.count == 3)
        #expect(aggregate.counts["good"] == 2)
        #expect(aggregate.counts["bad"] == 1)
        #expect(aggregate.mostCommonLabel == "good")
        #expect(aggregate.leastCommonLabel == "bad")
    }

    @Test("judge: reasoning emitted as separate Base results, excluded from metrics")
    func judgeReasoning() async throws {
        let metric = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let stub = StubJudge([
            RTSJudgeResponse(metricValue: "good", reasoning: "because A"),
            RTSJudgeResponse(metricValue: "bad", reasoning: "because B"),
        ])
        let output = try await judge(metrics: [metric], reasoning: true, stub: stub)
            .run([dataPoint(), dataPoint()])

        let base = baseLeaves(output)
        let judgeResults = base.filter { $0.resultName.hasPrefix("JudgeResult/") }
        let reasoningResults = base.filter { $0.resultName.hasPrefix("JudgeReasoning/") }
        #expect(judgeResults.count == 2)
        #expect(reasoningResults.count == 2)
        // Reasoning results reference a distinct (implicit) metric, never the categorical metric.
        #expect(reasoningResults.allSatisfy { $0.metricId != metric.identifier })
        // metrics_map carries only the configured categorical metric.
        #expect(output.metrics.count == 1)
        #expect(output.metrics.first?.identifier == metric.identifier)
    }

    @Test("judge: reasoning disabled emits no reasoning results")
    func judgeReasoningOff() async throws {
        let metric = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let stub = StubJudge([RTSJudgeResponse(metricValue: "good", reasoning: "ignored")])
        let output = try await judge(metrics: [metric], reasoning: false, stub: stub)
            .run([dataPoint()])

        let reasoning = baseLeaves(output).filter { $0.resultName.hasPrefix("JudgeReasoning/") }
        #expect(reasoning.isEmpty)
    }

    @Test("judge: out-of-category labels resolve to unknown on counts AND leaves (they agree)")
    func judgeUnknownBucket() async throws {
        let metric = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let stub = StubJudge([
            RTSJudgeResponse(metricValue: "good", reasoning: nil),
            RTSJudgeResponse(metricValue: "spectacular", reasoning: nil),   // not declared
        ])
        let output = try await judge(metrics: [metric], reasoning: false, stub: stub)
            .run([dataPoint(), dataPoint()])

        let aggregate = try #require(categoricalAggregates(output).first)
        #expect(aggregate.counts["good"] == 1)
        #expect(aggregate.counts["bad"] == 0)
        #expect(aggregate.counts["unknown"] == 1)
        #expect(aggregate.categories.contains("unknown"))

        // The out-of-category label is resolved to "unknown" on the LEAF too — the raw "spectacular"
        // never reaches the JSON, so `counts` and the child leaves are reconcilable without re-folding.
        let leafValues: [String] = baseLeaves(output).compactMap { leaf in
            if case .string(let text) = leaf.value {
                return text
            }
            return nil
        }
        #expect(leafValues.sorted() == ["good", "unknown"])
        #expect(!leafValues.contains("spectacular"))
        // Consistency invariant: every leaf value is a key present in the aggregate's counts.
        #expect(leafValues.allSatisfy { aggregate.counts[$0] != nil })
    }

    @Test("judge: multiple metrics each get their own aggregate")
    func judgeMultipleMetrics() async throws {
        let helpfulness = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let toxicity = RTSCategoricalMetric(name: "Toxicity", categories: ["safe", "toxic"])
        let stub = StubJudge([RTSJudgeResponse(metricValue: "good", reasoning: nil)])
        let output = try await judge(metrics: [helpfulness, toxicity], reasoning: false, stub: stub)
            .run([dataPoint(), dataPoint()])

        let names = Set(categoricalAggregates(output).map { $0.name })
        #expect(names == ["Aggregate/Helpfulness", "Aggregate/Toxicity"])
        #expect(output.metrics.count == 2)
    }

    // MARK: - End-to-end through evaluate()

    @Test("evaluate with a judge produces a round-tripping report")
    func evaluateWithJudge() async throws {
        let metric = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let stub = StubJudge([RTSJudgeResponse(metricValue: "good", reasoning: "r")])
        let judgeEvaluator = judge(metrics: [metric], reasoning: true, stub: stub)

        let reports = await RTSEvaluation.evaluate(
            data: [dataPoint(agent: "A"), dataPoint(agent: "A")],
            evaluators: [judgeEvaluator],
            persist: false
        )
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.metricsMap[metric.identifier] != nil)

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(RTSEvaluationReport.self, from: encoded)
        #expect(decoded.evaluatorResults.count == 1)
    }

    // MARK: - Concurrency limiter

    @Test("concurrency limiter bounds in-flight operations")
    func limiterBounds() async throws {
        let limiter = RTSConcurrencyLimiter(limit: 2)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try? await limiter.withPermit {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.exit()
                    }
                }
            }
        }
        #expect(await tracker.maxConcurrent <= 2)
        #expect(await tracker.maxConcurrent >= 1)
    }

    @Test("unbounded limiter never blocks")
    func limiterUnbounded() async throws {
        let limiter = RTSConcurrencyLimiter(limit: nil)
        let value = try await limiter.withPermit {
            42
        }
        #expect(value == 42)
    }

    // MARK: - Progress reporting

    private func evaluatingEvents(_ events: [RTSEvaluationEvent]) -> [(completed: Int, total: Int)] {
        events.compactMap { event in
            guard case .evaluating(let completed, let total) = event else { return nil }
            return (completed, total)
        }
    }

    @Test("progress: evaluating total = datapoints × evaluators, and completed reaches it")
    func progressReachesTotal() async throws {
        let metric = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let stub = StubJudge([RTSJudgeResponse(metricValue: "good", reasoning: nil)])
        let judgeEvaluator = judge(metrics: [metric], reasoning: false, stub: stub)
        let data = [dataPoint(agent: "A"), dataPoint(agent: "A"), dataPoint(agent: "A")]

        let collector = EventCollector()
        _ = await RTSEvaluation.evaluate(
            data: data,
            evaluators: [judgeEvaluator],   // 1 evaluator × 3 datapoints
            persist: false,
            onEvent: { collector.add($0) }
        )

        let progress = evaluatingEvents(collector.snapshot())
        #expect(!progress.isEmpty)
        #expect(progress.allSatisfy { $0.total == 3 })       // 3 datapoints × 1 evaluator
        #expect(progress.map(\.completed).max() == 3)        // completed reaches total
    }

    @Test("progress: failed judge calls emit .failed but still tick completion")
    func progressFailuresStillComplete() async throws {
        let metric = RTSCategoricalMetric(name: "Helpfulness", categories: ["good", "bad"])
        let throwingJudge = RTSJudgeEvaluator(
            provider: .appleAI,
            metrics: [metric],
            includesReasoning: false,
            limiter: RTSConcurrencyLimiter(limit: nil),
            judgeCall: { _, _ in throw RTSError.decodingFailed("boom") }
        )
        let data = [dataPoint(agent: "A"), dataPoint(agent: "A")]

        let collector = EventCollector()
        _ = await RTSEvaluation.evaluate(
            data: data,
            evaluators: [throwingJudge],
            persist: false,
            onEvent: { collector.add($0) }
        )

        let events = collector.snapshot()
        let failures = events.filter { if case .evaluationFailed = $0 { return true } else { return false } }
        #expect(!failures.isEmpty)                                   // failures surfaced
        #expect(evaluatingEvents(events).map(\.completed).max() == 2)  // bar still reaches total
    }

    @Test("ingest: concurrent + fail-soft — bad files skipped, each counted, .ingestFailed emitted")
    func ingestFailSoft() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rts-ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var urls: [URL] = []
        for index in 0..<3 {
            let url = dir.appendingPathComponent("bad\(index).json")
            try "not valid json".write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }

        let collector = EventCollector()
        let data = await RTSEvaluationIngest.agentDataPoints(fromFiles: urls, onEvent: { collector.add($0) })

        #expect(data.isEmpty)   // all three failed to decode
        let events = collector.snapshot()
        let failed = events.filter { if case .ingestFailed = $0 { return true } else { return false } }
        #expect(failed.count == 3)
        let ingesting = events.compactMap { event -> (Int, Int) in
            if case .ingesting(let completed, let total, _) = event { return (completed, total) }
            return (-1, -1)
        }.filter { $0.0 >= 0 }
        #expect(ingesting.map(\.0).max() == 3)          // every file counted (bar reaches total)
        #expect(ingesting.allSatisfy { $0.1 == 3 })     // totalFiles == 3
    }

    @Test("manager: run() over no files emits .finished(0)")
    func managerEmitsFinished() async throws {
        let manager = RTSEvaluationManager()
        let collector = EventCollector()
        let cancellable = manager.progressPublisher.sink { collector.add($0) }
        defer { cancellable.cancel() }

        _ = await manager.run(fromFiles: [], evaluators: [])

        let finished = collector.snapshot().contains {
            if case .finished(let count) = $0 { return count == 0 }
            return false
        }
        #expect(finished)
    }
}
