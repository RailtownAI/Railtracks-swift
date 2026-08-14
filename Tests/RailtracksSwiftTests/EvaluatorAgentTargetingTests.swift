//
//  EvaluatorAgentTargetingTests.swift
//  RailtracksSwiftTests
//
//  Per-evaluator agent targeting: RTSEvaluation.evaluate(data:assignments:). See
//  docs/evaluator-agent-targeting.md.
//

import Testing
import Foundation
@testable import RailtracksSwift

/// Minimal evaluator: records nothing, ticks progress once per data point, and emits an empty result
/// tagged with its name so tests can see which evaluators ran on which agent.
private struct StubEvaluator: RTSEvaluator {
    let name: String
    var identifier: String { "id-\(name)" }

    func run(_ data: [RTSAgentDataPoint], context: RTSEvaluatorRunContext?) async throws -> RTSEvaluatorOutput {
        for _ in data {
            context?.reportProgress()
        }
        let result = RTSEvaluatorResult(
            evaluatorName: name,
            evaluatorId: identifier,
            metricResults: [],
            aggregateResults: RTSAggregateForest(roots: [], nodes: [:])
        )
        return RTSEvaluatorOutput(result: result, metrics: [])
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

extension RailtracksSwiftTestSuite {
    @Suite("Evaluator agent targeting")
    struct EvaluatorAgentTargetingTests {

        private func dataPoint(agent: String) -> RTSAgentDataPoint {
            RTSAgentDataPoint(
                id: UUID(),
                sessionID: UUID(),
                agentName: agent,
                agentInput: .object([:]),
                agentOutput: .object([:]),
                llmCalls: [],
                toolNames: [],
                toolCalls: []
            )
        }

        /// The evaluator names that appear in a given agent's report.
        private func evaluators(for agent: String, in reports: [RTSEvaluationReport]) -> Set<String> {
            let report = reports.first { $0.agents.first?.agentName == agent }
            return Set(report?.evaluatorResults.map { $0.evaluatorName } ?? [])
        }

        @Test("assignments route evaluators to their targeted agents (union on overlap)")
        func targeting() async throws {
            let a = StubEvaluator(name: "A")
            let b = StubEvaluator(name: "B")
            let c = StubEvaluator(name: "C")
            let d = StubEvaluator(name: "D")
            let data = (1...6).map { dataPoint(agent: "agent\($0)") }
            let agents1to5 = (1...5).map { "agent\($0)" }

            let reports = await RTSEvaluation.evaluate(
                data: data,
                assignments: [
                    .init(evaluator: a, agents: agents1to5),
                    .init(evaluator: b, agents: agents1to5),
                    .init(evaluator: c, agents: ["agent5"]),
                    .init(evaluator: d, agents: ["agent6"]),
                ],
                persist: false
            )

            #expect(reports.count == 6)                                   // every agent targeted
            #expect(evaluators(for: "agent1", in: reports) == ["A", "B"])
            #expect(evaluators(for: "agent4", in: reports) == ["A", "B"])
            #expect(evaluators(for: "agent5", in: reports) == ["A", "B", "C"])   // union of overlapping scopes
            #expect(evaluators(for: "agent6", in: reports) == ["D"])
        }

        @Test("an agent with no matching assignment is skipped (no report)")
        func untargetedSkipped() async throws {
            let a = StubEvaluator(name: "A")
            let data = [dataPoint(agent: "targeted"), dataPoint(agent: "untargeted")]

            let reports = await RTSEvaluation.evaluate(
                data: data,
                assignments: [.init(evaluator: a, agents: ["targeted"])],
                persist: false
            )

            #expect(reports.count == 1)
            #expect(reports.first?.agents.first?.agentName == "targeted")
        }

        @Test("no map: the evaluators overload applies all evaluators to all agents")
        func allOnAll() async throws {
            let a = StubEvaluator(name: "A")
            let b = StubEvaluator(name: "B")
            let data = [dataPoint(agent: "x"), dataPoint(agent: "y")]

            let reports = await RTSEvaluation.evaluate(data: data, evaluators: [a, b], persist: false)

            #expect(reports.count == 2)
            #expect(evaluators(for: "x", in: reports) == ["A", "B"])
            #expect(evaluators(for: "y", in: reports) == ["A", "B"])
        }

        @Test("the same evaluator assigned twice to an agent is deduped (runs once)")
        func dedup() async throws {
            let a = StubEvaluator(name: "A")
            let data = [dataPoint(agent: "x")]

            let reports = await RTSEvaluation.evaluate(
                data: data,
                assignments: [
                    .init(evaluator: a, agents: ["x"]),
                    .init(evaluator: a, agents: nil),   // nil also covers "x" → would double up without dedup
                ],
                persist: false
            )

            #expect(reports.count == 1)
            #expect(reports.first?.evaluatorResults.filter { $0.evaluatorName == "A" }.count == 1)
        }

        @Test("progress total = Σ per agent (data points × its evaluators), and completed reaches it")
        func progressExactTotal() async throws {
            let a = StubEvaluator(name: "A")
            let b = StubEvaluator(name: "B")
            let c = StubEvaluator(name: "C")
            // agent x: 2 data points; agent y: 1 data point.
            let data = [dataPoint(agent: "x"), dataPoint(agent: "x"), dataPoint(agent: "y")]
            // A,B on x → 2 pts × 2 evals = 4 ; C on y → 1 pt × 1 eval = 1 ; total = 5.
            let collector = EventCollector()

            _ = await RTSEvaluation.evaluate(
                data: data,
                assignments: [
                    .init(evaluator: a, agents: ["x"]),
                    .init(evaluator: b, agents: ["x"]),
                    .init(evaluator: c, agents: ["y"]),
                ],
                persist: false,
                onEvent: { collector.add($0) }
            )

            let progress = collector.snapshot().compactMap { event -> (completed: Int, total: Int)? in
                guard case .evaluating(let completed, let total) = event else { return nil }
                return (completed, total)
            }
            #expect(!progress.isEmpty)
            #expect(progress.allSatisfy { $0.total == 5 })
            #expect(progress.map(\.completed).max() == 5)
        }
    }
}
