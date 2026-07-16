//
//  EvaluationJudgeTests.swift
//  RailtracksSwiftTests
//
//  Phase 3: the LLM judge evaluator + the concurrency limiter. The judge is driven by a stubbed
//  RTSJudgeCall so the aggregation logic is verified deterministically with no live LLM.
//

import Testing
import Foundation
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

    @Test("judge: out-of-category labels fold into an unknown bucket; leaf keeps raw value")
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
        // The leaf preserves the raw label rather than rewriting it to "unknown".
        let keptRaw = baseLeaves(output).contains { leaf in
            if case .string(let text) = leaf.value {
                return text == "spectacular"
            }
            return false
        }
        #expect(keptRaw)
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
}
