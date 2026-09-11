//
//  EvaluationEvaluatorTests.swift
//  RailtracksSwiftTests
//
//  Phase 2: the two prebuilt evaluators + the evaluate() runner.
//

import Testing
import Foundation
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {
    @Suite("Evaluation — Phase 2")
    struct EvaluationEvaluatorTests {

        // MARK: - Builders

        private func toolCall(
            _ name: String,
            runtime: Double,
            status: RTSFlowStatus
        ) -> RTSEvalToolCall {
            RTSEvalToolCall(
                id: UUID(),
                name: name,
                arguments: RTSToolArguments(args: [], kwargs: [:]),
                output: .null,
                runtime: runtime,
                status: status
            )
        }

        private func llmCall(
            index: Int,
            inputTokens: Int,
            outputTokens: Int,
            cost: Double,
            latency: Double
        ) -> RTSLLMCall {
            RTSLLMCall(
                modelName: "gpt",
                modelProvider: "OpenAI",
                input: [],
                output: RTSLLMIO(role: .assistant, content: .null),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalCost: cost,
                latency: latency,
                index: index
            )
        }

        private func dataPoint(
            agent: String,
            tools: [RTSEvalToolCall] = [],
            llm: [RTSLLMCall] = []
        ) -> RTSAgentDataPoint {
            RTSAgentDataPoint(
                id: UUID(),
                sessionID: UUID(),
                agentName: agent,
                agentInput: .object([:]),
                agentOutput: .object([:]),
                llmCalls: llm,
                toolNames: Set(tools.map { $0.name }),
                toolCalls: tools
            )
        }

        // Extract (resultName, toolName, numericValue) from tool metric results.
        private func toolLeaves(
            _ output: RTSEvaluatorOutput
        ) -> [(name: String, tool: String, value: Double?)] {
            output.result.metricResults.compactMap { result in
                guard case .tool(let leaf) = result else { return nil }
                return (leaf.resultName, leaf.toolName, leaf.value.numberValue)
            }
        }

        private func toolAggregates(_ output: RTSEvaluatorOutput) -> [RTSToolAggregate] {
            output.result.aggregateResults.nodes.values.compactMap { node in
                guard case .toolAggregate(let aggregate) = node else { return nil }
                return aggregate
            }
        }

        private func llmAggregates(_ output: RTSEvaluatorOutput) -> [RTSLLMInferenceAggregate] {
            output.result.aggregateResults.nodes.values.compactMap { node in
                guard case .llmAggregate(let aggregate) = node else { return nil }
                return aggregate
            }
        }

        // MARK: - ToolUseEvaluator (the fix)

        @Test("tool-use evaluator: one runtime + one 0/1 failure leaf per call, correct rates")
        func toolUseEvaluator() async throws {
            let point = dataPoint(agent: "Triage", tools: [
                toolCall("search", runtime: 0.4, status: .completed),
                toolCall("search", runtime: 0.6, status: .failed),
                toolCall("lookup", runtime: 0.2, status: .completed),
            ])
            let output = try await RTSToolUseEvaluator().run([point])
            let leaves = toolLeaves(output)

            // Runtime: exactly one per call (no duplicates), values 0.2/0.4/0.6.
            let runtimes = leaves.filter { $0.name.hasPrefix("Runtime/") }
            #expect(runtimes.count == 3)
            #expect(runtimes.compactMap { $0.value }.sorted() == [0.2, 0.4, 0.6])

            // ToolFailure: a real 0/1 per call (fix), exactly one failure.
            let failures = leaves.filter { $0.name.hasPrefix("ToolFailure/") }
            #expect(failures.count == 3)
            #expect(Set(failures.compactMap { $0.value }) == [0, 1])
            #expect(failures.compactMap { $0.value }.reduce(0, +) == 1)

            // FailureRate: search 0.5, lookup 0.
            let rates = Dictionary(uniqueKeysWithValues:
                leaves.filter { $0.name.hasPrefix("FailureRate/") }.map { ($0.tool, $0.value) })
            #expect(rates["search"] == 0.5)
            #expect(rates["lookup"] == 0.0)

            // UsageCount: search 2, lookup 1.
            let counts = Dictionary(uniqueKeysWithValues:
                leaves.filter { $0.name.hasPrefix("UsageCount/") }.map { ($0.tool, $0.value) })
            #expect(counts["search"] == 2)
            #expect(counts["lookup"] == 1)

            // A Runtime aggregate for `search` reports mean 0.5 over [0.4, 0.6].
            let searchRuntimeAgg = toolAggregates(output).first {
                $0.toolName == "search" && $0.name == "Aggregate/Runtime" && $0.values.sorted() == [0.4, 0.6]
            }
            #expect(searchRuntimeAgg?.mean == 0.5)

            // Four metrics reported.
            #expect(output.metrics.count == 4)
        }

        // MARK: - LLMInferenceEvaluator

        @Test("llm-inference evaluator: per-call leaves + aggregate across runs by call index")
        func llmInferenceEvaluator() async throws {
            let run1 = dataPoint(agent: "Chat", llm: [llmCall(index: 0, inputTokens: 100, outputTokens: 50, cost: 0.01, latency: 1.2)])
            let run2 = dataPoint(agent: "Chat", llm: [llmCall(index: 0, inputTokens: 200, outputTokens: 80, cost: 0.02, latency: 0.9)])
            let output = try await RTSLLMInferenceEvaluator().run([run1, run2])

            // 4 metric leaves per call × 2 calls.
            let llmLeafCount = output.result.metricResults.filter {
                if case .llm = $0 { return true }
                return false
            }.count
            #expect(llmLeafCount == 8)

            // InputTokens aggregate for call index 0 spans both runs → mean 150.
            let inputAgg = llmAggregates(output).first {
                $0.name.contains("InputTokens") && $0.llmCallIndex == 0
            }
            #expect(inputAgg?.values.sorted() == [100, 200])
            #expect(inputAgg?.mean == 150)

            #expect(output.metrics.count == 4)
        }

        // MARK: - Runner

        @Test("evaluate produces one report per agent and each round-trips")
        func evaluateProducesReports() async throws {
            let triage = dataPoint(agent: "Triage", tools: [toolCall("search", runtime: 0.3, status: .completed)])
            let chat = dataPoint(agent: "Chat", llm: [llmCall(index: 0, inputTokens: 10, outputTokens: 5, cost: 0.001, latency: 0.5)])

            let reports = await RTSEvaluation.evaluate(
                data: [triage, chat],
                evaluators: [RTSToolUseEvaluator(), RTSLLMInferenceEvaluator()],
                name: "unit",
                persist: false
            )

            // One report per agent.
            #expect(reports.count == 2)
            #expect(Set(reports.flatMap { $0.agents.map { $0.agentName } }) == ["Triage", "Chat"])

            // Each report round-trips structurally.
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            for report in reports {
                let decoded = try decoder.decode(RTSEvaluationReport.self, from: encoder.encode(report))
                #expect(decoded.evaluatorResults.count == report.evaluatorResults.count)
                #expect(decoded.metricsMap.count == report.metricsMap.count)
                #expect(decoded.evaluationName == "unit")
            }
        }

        @Test("evaluate honors the agents filter")
        func evaluateAgentsFilter() async throws {
            let triage = dataPoint(agent: "Triage", tools: [toolCall("search", runtime: 0.3, status: .completed)])
            let chat = dataPoint(agent: "Chat", tools: [toolCall("reply", runtime: 0.1, status: .completed)])

            let reports = await RTSEvaluation.evaluate(
                data: [triage, chat],
                evaluators: [RTSToolUseEvaluator()],
                agents: ["Chat"],
                persist: false
            )
            #expect(reports.count == 1)
            #expect(reports.first?.agents.first?.agentName == "Chat")
        }

        @Test("evaluate persists a report file to evaluationOutputDirectory")
        func evaluatePersists() async throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-eval-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            RailtracksSwift.outputDirectory = base
            // Derived, not set: reports land in the fixed `evaluations` subfolder.
            let dir = RailtracksSwift.evaluationOutputDirectory

            let point = dataPoint(agent: "Triage", tools: [toolCall("search", runtime: 0.3, status: .completed)])
            let reports = await RTSEvaluation.evaluate(
                data: [point],
                evaluators: [RTSToolUseEvaluator()]
            )

            let files = try FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            #expect(files.count == reports.count)
            // The written file decodes back into a report.
            let decoded = try JSONDecoder().decode(RTSEvaluationReport.self, from: Data(contentsOf: files[0]))
            #expect(decoded.evaluatorResults.count == 1)
        }
    }
}
