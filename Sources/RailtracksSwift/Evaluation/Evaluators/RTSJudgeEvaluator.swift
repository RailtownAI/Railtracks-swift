//
//  RTSJudgeEvaluator.swift
//  RailtracksSwift
//

import Foundation

/// The structured response the judge LLM returns for one (metric × datapoint) call. `metricValue`
/// is the chosen category label (kept as a raw string — validated/bucketed at aggregation, matching
/// Python's free-string `metric_value`). Keys are internal to the judge; never written to the report.
/// The schema is hand-written rather than via `@RTSSchema` because that macro can't emit a `public`
/// `rtsSchema`, and this type must be public so tests can inject a stub `RTSJudgeCall`.
public struct RTSJudgeResponse: Codable, Sendable {
    public let metricValue: String
    public let reasoning: String?

    public init(metricValue: String, reasoning: String?) {
        self.metricValue = metricValue
        self.reasoning = reasoning
    }

    // TODO (future improvement): this full schema is used unconditionally, so when
    // `RTSJudgeEvaluator.includesReasoning` is false the LLM still generates a `reasoning` string that
    // we then discard (only the prompt + leaf emission honor the flag, not the schema). Selecting a
    // metricValue-only schema per that flag (threaded through `gatewayJudgeCall`) would avoid the wasted
    // generation. Left as-is for now: report output is already correct and this matches Python.
    public static let rtsSchema = RTSOutputSchema(
        name: "RTSJudgeResponse",
        type: .object(
            name: "RTSJudgeResponse",
            properties: [
                RTSOutputSchema(name: "metricValue", type: .string),
                // `reasoning` must be REQUIRED (not optional): OpenAI structured output runs in strict
                // mode, which demands every property appear in `required` — an optional field is omitted
                // from `required` and the request is rejected (400), silently failing every judge call.
                // The Swift property stays `String?` for decode tolerance across providers.
                RTSOutputSchema(name: "reasoning", type: .string),
            ]
        )
    )
}

/// The judge's one dependency: run a single judge prompt and return its structured response. This is
/// the injected seam — production wires it to `RTSFlow.run(..., savesTrace: false)` (see the
/// convenience initializer); tests inject a stub returning canned labels, so the aggregation logic is
/// unit-testable with no LLM. (The seam exists for testability, not provider support — the gateway
/// already handles both Conduit providers and Apple FoundationModels.)
public typealias RTSJudgeCall = @Sendable (_ system: String, _ user: String) async throws -> RTSJudgeResponse

/// LLM-as-a-judge evaluator: a concrete, directly-usable built-in (mirrors Python's `JudgeEvaluator`).
/// For each (categorical metric × data point) it asks an LLM to pick one of the metric's categories,
/// then aggregates the verdicts into one `CategoricalAggregate` per metric. The *subject* of the
/// judgement is defined entirely by the metric you pass (name/categories/description); the *model* is
/// the `provider`. Both are constructor params — configure, don't subclass.
public struct RTSJudgeEvaluator: RTSEvaluator {
    public let name = "JudgeEvaluator"

    public let metrics: [RTSCategoricalMetric]
    public let provider: RTSLLMProvider
    public let systemPrompt: String?
    public let includesReasoning: Bool

    private let judgeCall: RTSJudgeCall
    private let limiter: RTSConcurrencyLimiter?

    public var identifier: String {
        RTSEvaluatorIdentity.identifier(
            typeName: name,
            config: [
                "llm=\(provider.description)",
                "provider=\(provider.providerName)",
                "system_prompt=\(systemPrompt ?? Self.defaultSystemPrompt)",
                "metrics=\(metrics.map { $0.identifier }.sorted().joined(separator: ","))",
                "reasoning=\(includesReasoning)",
            ]
        )
    }

    /// App-facing initializer: builds the production `RTSJudgeCall` from the model + gateway, wired to
    /// a trace-less `RTSFlow` sub-run. Pass the model and your categorical metric(s) and it runs.
    public init(
        provider: RTSLLMProvider,
        gateway: RTSLLMGateway,
        metrics: [RTSCategoricalMetric],
        systemPrompt: String? = nil,
        includesReasoning: Bool = true
    ) {
        self.init(
            provider: provider,
            metrics: metrics,
            systemPrompt: systemPrompt,
            includesReasoning: includesReasoning,
            limiter: nil,
            judgeCall: Self.gatewayJudgeCall(provider: provider, gateway: gateway)
        )
    }

    /// Designated initializer: takes the `RTSJudgeCall` seam directly (tests / advanced use) and an
    /// optional limiter override. When `limiter` is nil, `run` resolves the shared per-provider limiter.
    public init(
        provider: RTSLLMProvider,
        metrics: [RTSCategoricalMetric],
        systemPrompt: String? = nil,
        includesReasoning: Bool = true,
        limiter: RTSConcurrencyLimiter? = nil,
        judgeCall: @escaping RTSJudgeCall
    ) {
        self.provider = provider
        self.metrics = metrics
        self.systemPrompt = systemPrompt
        self.includesReasoning = includesReasoning
        self.limiter = limiter
        self.judgeCall = judgeCall
    }

    // MARK: - Run

    public func run(_ data: [RTSAgentDataPoint]) async throws -> RTSEvaluatorOutput {
        let limiter: RTSConcurrencyLimiter
        if let injected = self.limiter {
            limiter = injected
        } else {
            limiter = await RTSConcurrencyLimiter.shared(for: provider.kind)
        }
        let jobs = await invoke(data: data, limiter: limiter)

        var jobsByMetric: [Int: [JudgeJob]] = [:]
        for job in jobs {
            jobsByMetric[job.metricIndex, default: []].append(job)
        }

        var metricResults: [RTSMetricResult] = []
        var builder = RTSForestBuilder()

        for (metricIndex, metric) in metrics.enumerated() {
            var mainLeaves: [RTSBaseMetricResult] = []
            for job in jobsByMetric[metricIndex] ?? [] {
                guard let response = job.response else {
                    continue
                }

                let resultLeaf = RTSBaseMetricResult(
                    identifier: UUID().uuidString,
                    resultName: "JudgeResult/\(metric.name)",
                    metricId: metric.identifier,
                    agentDataId: [job.dataId],
                    value: .string(response.metricValue)
                )
                metricResults.append(.base(resultLeaf))
                builder.add(.base(resultLeaf))
                mainLeaves.append(resultLeaf)

                if includesReasoning {
                    if let reasoningText = response.reasoning {
                        // Separate Base result under a distinct "<name>_reasoning" metric. Not added to
                        // the forest and not in metrics_map (matches Python).
                        let reasoningLeaf = RTSBaseMetricResult(
                            identifier: UUID().uuidString,
                            resultName: "JudgeReasoning/\(metric.name)",
                            metricId: Self.reasoningMetricIdentifier(for: metric),
                            agentDataId: [job.dataId],
                            value: .string(reasoningText)
                        )
                        metricResults.append(.base(reasoningLeaf))
                    } else {
                        log.warning("🧪 no reasoning returned for judge metric \(metric.name), datapoint \(job.dataId)")
                    }
                }
            }

            if !mainLeaves.isEmpty {
                addCategoricalAggregate(metric: metric, leaves: mainLeaves, into: &builder)
            }
        }

        let result = RTSEvaluatorResult(
            evaluatorName: name,
            evaluatorId: identifier,
            metricResults: metricResults,
            aggregateResults: builder.build()
        )
        // metrics_map carries only the configured categorical metrics (reasoning metrics excluded).
        return RTSEvaluatorOutput(
            result: result,
            metrics: metrics.map { .categorical($0) }
        )
    }

    // MARK: - Level-B fan-out

    private struct JudgeJob: Sendable {
        let metricIndex: Int
        let dataId: String
        let response: RTSJudgeResponse?
    }

    /// Fan out every (metric × datapoint) judge call concurrently, each bounded by the per-provider
    /// limiter. A failed call becomes a `nil` response (logged and skipped) so one bad call can't sink
    /// the evaluation.
    private func invoke(
        data: [RTSAgentDataPoint],
        limiter: RTSConcurrencyLimiter
    ) async -> [JudgeJob] {
        let judgeCall = self.judgeCall
        return await withTaskGroup(of: JudgeJob.self, returning: [JudgeJob].self) { group in
            for (metricIndex, metric) in metrics.enumerated() {
                let system = generateSystemPrompt(for: metric)
                let metricName = metric.name
                for datapoint in data {
                    let user = generateUserPrompt(for: datapoint)
                    let dataId = datapoint.id.uuidString
                    group.addTask {
                        do {
                            let response = try await limiter.withPermit {
                                try await judgeCall(system, user)
                            }
                            return JudgeJob(
                                metricIndex: metricIndex,
                                dataId: dataId,
                                response: response
                            )
                        } catch {
                            log.error("🧪 judge failed for metric \(metricName), datapoint \(dataId): \(error)")
                            return JudgeJob(
                                metricIndex: metricIndex,
                                dataId: dataId,
                                response: nil
                            )
                        }
                    }
                }
            }
            var collected: [JudgeJob] = []
            for await job in group {
                collected.append(job)
            }
            return collected
        }
    }

    // MARK: - Aggregation

    /// Build one `CategoricalAggregate` over a metric's verdict leaves. `counts` zero-initializes the
    /// declared categories (matching Python) and folds any out-of-category label into an `"unknown"`
    /// bucket (our lossless superset — Python silently drops them). most/least-common follow the counts.
    private func addCategoricalAggregate(
        metric: RTSCategoricalMetric,
        leaves: [RTSBaseMetricResult],
        into builder: inout RTSForestBuilder
    ) {
        var counts: [String: Int] = [:]
        for category in metric.categories {
            counts[category] = 0
        }
        var sawUnknown = false
        for leaf in leaves {
            let rawLabel: String
            if case .string(let text) = leaf.value {
                rawLabel = text
            } else {
                rawLabel = "unknown"
            }
            if counts[rawLabel] != nil {
                counts[rawLabel]! += 1
            } else {
                counts["unknown", default: 0] += 1
                sawUnknown = true
            }
        }

        var orderedLabels = metric.categories
        if sawUnknown {
            orderedLabels.append("unknown")
        }

        var mostCommonLabel: String?
        var leastCommonLabel: String?
        var maximumCount = Int.min
        var minimumCount = Int.max
        for label in orderedLabels {
            let count = counts[label] ?? 0
            if count > maximumCount {           // strict > → first in declared order wins ties
                maximumCount = count
                mostCommonLabel = label
            }
            if count <= minimumCount {          // <= → last in declared order wins ties (matches Python)
                minimumCount = count
                leastCommonLabel = label
            }
        }

        let node = RTSCategoricalAggregate(
            identifier: UUID().uuidString,
            type: "CategoricalAggregate",
            name: "Aggregate/\(metric.name)",
            metric: .categorical(metric),
            children: leaves.map { $0.identifier },
            categories: orderedLabels,
            counts: counts,
            mostCommonLabel: mostCommonLabel,
            leastCommonLabel: leastCommonLabel
        )
        builder.add(.categoricalAggregate(node))
        builder.addRoot(node.identifier)
    }

    // MARK: - Prompt building (ports judge_evaluator.yaml + _generate_*_prompt)

    static let defaultSystemPrompt =
        "You are an expert evaluator. Your task is to assess the quality of Agentic AI."

    private func generateSystemPrompt(for metric: RTSCategoricalMetric) -> String {
        var systemMessage = systemPrompt ?? Self.defaultSystemPrompt
        systemMessage += "\nPlease provide your feedback using the following criteria:\n"
        systemMessage += criteriaString(for: metric)
        if includesReasoning {
            systemMessage += "\nPlease provide a detailed reasoning for your evaluation."
        }
        return systemMessage
    }

    private func criteriaString(for metric: RTSCategoricalMetric) -> String {
        var lines = ["\(metric.name):"]
        if let description = metric.description {
            lines.append(description)
        }
        lines.append("Respond with exactly one of these categories: [\(metric.categories.joined(separator: ", "))]")
        return lines.joined(separator: "\n")
    }

    private func generateUserPrompt(for datapoint: RTSAgentDataPoint) -> String {
        let input = promptString(datapoint.agentInput)
        let output = agentOutputString(datapoint.agentOutput)
        return "Agent Input: \(input)\nAgent Output: \(output)"
    }

    /// Agent output is an object keyed by `message_history` (matching Python's
    /// `agent_output.get("message_history", "")`); fall back to the whole value otherwise.
    private func agentOutputString(_ value: RTSValue) -> String {
        if case .object(let object) = value, let history = object["message_history"] {
            return promptString(history)
        }
        return promptString(value)
    }

    private func promptString(_ value: RTSValue) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }

    // MARK: - Identity helpers

    /// Deterministic id for a metric's implicit reasoning metric. Only intra-report consistency
    /// matters, so the format is ours; the reasoning metric is never serialized as a metric.
    static func reasoningMetricIdentifier(for metric: RTSCategoricalMetric) -> String {
        RailtracksSwift.equalityHash("Metric|name=\(metric.name)_reasoning")
    }

    // MARK: - Production judge call

    /// Builds the production `RTSJudgeCall`: a judge `RTSAgent` (structured against `RTSJudgeResponse`)
    /// run through a trace-less `RTSFlow`, decoding the returned JSON into `RTSJudgeResponse`.
    static func gatewayJudgeCall(
        provider: RTSLLMProvider,
        gateway: RTSLLMGateway
    ) -> RTSJudgeCall {
        return { system, user in
            let agent = RTSAgent(
                llmProvider: provider,
                name: "JudgeAgent",
                outputSchema: RTSJudgeResponse.rtsSchema
            )
            let flow = RTSFlow(title: "JudgeEvaluatorFlow", savesTrace: false)
            let resultString = try await flow.run(
                agent: agent,
                prompt: user,
                gateway: gateway,
                systemMessage: system
            )
            guard let data = resultString.data(using: .utf8) else {
                throw RTSError.decodingFailed("Judge result was not valid UTF-8")
            }
            return try JSONDecoder().decode(RTSJudgeResponse.self, from: data)
        }
    }
}
