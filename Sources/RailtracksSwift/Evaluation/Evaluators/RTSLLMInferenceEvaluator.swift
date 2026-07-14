//
//  RTSLLMInferenceEvaluator.swift
//  RailtracksSwift
//

import Foundation

/// Analyzes LLM inference statistics across an agent's runs: per-call input/output tokens, token
/// cost, and latency, aggregated by (model, provider, call index). Pure/deterministic — no LLM.
public struct RTSLLMInferenceEvaluator: RTSEvaluator {
    public let name = "LLMInferenceEvaluator"

    public var identifier: String {
        RTSEvaluatorIdentity.identifier(typeName: name)
    }

    private let inputTokens = RTSNumericalMetric(
        name: "InputTokens",
        metricType: .llmMetric,
        minValue: 0
    )
    private let outputTokens = RTSNumericalMetric(
        name: "OutputTokens",
        metricType: .llmMetric,
        minValue: 0
    )
    private let tokenCost = RTSNumericalMetric(
        name: "TokenCost",
        metricType: .llmMetric,
        minValue: 0.0
    )
    private let latency = RTSNumericalMetric(
        name: "Latency",
        metricType: .llmMetric,
        minValue: 0.0
    )

    public init() {}

    public func run(_ data: [RTSAgentDataPoint]) async throws -> RTSEvaluatorOutput {
        var builder = RTSForestBuilder()
        var metricResults: [RTSMetricResult] = []
        var leavesByMetric: [String: [RTSLLMMetricResult]] = [:]

        for datapoint in data {
            let agentDataId = datapoint.id.uuidString
            for call in datapoint.llmCalls {
                let entries: [(metric: RTSNumericalMetric, value: RTSValue)] = [
                    (inputTokens, call.inputTokens.map { .number(Double($0)) } ?? .null),
                    (outputTokens, call.outputTokens.map { .number(Double($0)) } ?? .null),
                    (tokenCost, call.totalCost.map { .number($0) } ?? .null),
                    (latency, call.latency.map { .number($0) } ?? .null),
                ]
                for entry in entries {
                    let leaf = RTSLLMMetricResult(
                        identifier: UUID().uuidString,
                        resultName: entry.metric.name,
                        metricId: entry.metric.identifier,
                        agentDataId: [agentDataId],
                        value: entry.value,
                        llmCallIndex: call.index,
                        modelName: call.modelName,
                        modelProvider: call.modelProvider
                    )
                    metricResults.append(.llm(leaf))
                    builder.add(.llm(leaf))
                    leavesByMetric[entry.metric.identifier, default: []].append(leaf)
                }
            }
        }

        for metric in [inputTokens, outputTokens, tokenCost, latency] {
            aggregate(
                metric: metric,
                leaves: leavesByMetric[metric.identifier] ?? [],
                into: &builder
            )
        }

        let result = RTSEvaluatorResult(
            evaluatorName: name,
            evaluatorId: identifier,
            metricResults: metricResults,
            aggregateResults: builder.build()
        )
        return RTSEvaluatorOutput(
            result: result,
            metrics: [.numerical(inputTokens), .numerical(outputTokens),
                      .numerical(tokenCost), .numerical(latency)]
        )
    }

    /// Group a metric's numeric leaves by (model, provider, call index) and add one aggregate each.
    private func aggregate(
        metric: RTSNumericalMetric,
        leaves: [RTSLLMMetricResult],
        into builder: inout RTSForestBuilder
    ) {
        var groups: [GroupKey: [RTSLLMMetricResult]] = [:]
        for leaf in leaves where leaf.value.numberValue != nil {
            let key = GroupKey(
                model: leaf.modelName,
                provider: leaf.modelProvider,
                index: leaf.llmCallIndex
            )
            groups[key, default: []].append(leaf)
        }

        for (key, groupLeaves) in groups {
            let children = groupLeaves.map { $0.identifier }
            let values = builder.numericValues(ofChildren: children)
            let stats = RTSAggregateStats.numeric(values)
            let node = RTSLLMInferenceAggregate(
                identifier: UUID().uuidString,
                type: "LLMInferenceAggregate",
                name: "Aggregate/\(metric.name)/\(key.model)/\(key.provider)/Call_\(key.index)",
                metric: .numerical(metric),
                children: children,
                llmCallIndex: key.index,
                modelName: key.model,
                modelProvider: key.provider,
                values: values,
                mean: stats.mean,
                minimum: stats.minimum,
                maximum: stats.maximum,
                median: stats.median,
                std: stats.std,
                mode: stats.mode
            )
            builder.add(.llmAggregate(node))
            builder.addRoot(node.identifier)
        }
    }

    private struct GroupKey: Hashable {
        let model: String
        let provider: String
        let index: Int
    }
}
