//
//  RTSToolUseEvaluator.swift
//  RailtracksSwift
//

import Foundation

/// Analyzes tool-usage patterns across an agent's runs: per-call failure and runtime, plus
/// per-(run, tool) failure rate and usage count, with runtime aggregated per-run then across runs.
/// Pure/deterministic — no LLM.
///
/// Divergence from Python `ToolUseEvaluator` (intentional bug fix — see the tracked issue):
/// Python appended the per-call runtime result to the `ToolFailure` bucket and emitted runtime
/// twice, so `ToolFailure` held runtimes, runtime leaves were duplicated, and orphan nodes
/// accumulated. This port emits exactly one `Runtime` leaf per call and a real `ToolFailure`
/// (0/1) leaf per call.
public struct RTSToolUseEvaluator: RTSEvaluator {
    public let name = "ToolUseEvaluator"

    public var identifier: String {
        RTSEvaluatorIdentity.identifier(typeName: name)
    }

    private let toolFailure = RTSNumericalMetric(
        name: "ToolFailure",
        metricType: .toolMetric,
        minValue: 0,
        maxValue: 1
    )
    private let runtime = RTSNumericalMetric(
        name: "Runtime",
        metricType: .toolMetric,
        minValue: 0.0
    )
    private let failureRate = RTSNumericalMetric(
        name: "FailureRate",
        metricType: .toolMetric,
        minValue: 0.0,
        maxValue: 1.0
    )
    private let usageCount = RTSNumericalMetric(
        name: "UsageCount",
        metricType: .toolMetric,
        minValue: 0
    )

    public init() {}

    private struct ToolKey: Hashable {
        let agentDataId: String
        let toolName: String
    }

    public func run(
        _ data: [RTSAgentDataPoint],
        context: RTSEvaluatorRunContext?
    ) async throws -> RTSEvaluatorOutput {
        var builder = RTSForestBuilder()
        var metricResults: [RTSMetricResult] = []
        var runtimeLeaves: [RTSToolMetricResult] = []
        var failureRateLeaves: [RTSToolMetricResult] = []
        var usageCountLeaves: [RTSToolMetricResult] = []

        var usage: [ToolKey: Int] = [:]
        var failures: [ToolKey: Int] = [:]

        // Phase 1 — per-call leaves.
        for datapoint in data {
            defer { context?.reportProgress() }   // one tick per data point finished
            let agentDataId = datapoint.id.uuidString
            for tool in datapoint.toolCalls {
                let key = ToolKey(agentDataId: agentDataId, toolName: tool.name)
                usage[key, default: 0] += 1
                if tool.status == .failed {
                    failures[key, default: 0] += 1
                }

                let runtimeLeaf = RTSToolMetricResult(
                    identifier: UUID().uuidString,
                    resultName: "\(runtime.name)/\(tool.name)",
                    metricId: runtime.identifier,
                    agentDataId: [agentDataId],
                    value: .number(tool.runtime ?? 0.0),
                    toolName: tool.name,
                    toolNodeId: tool.id.uuidString
                )
                metricResults.append(.tool(runtimeLeaf))
                builder.add(.tool(runtimeLeaf))
                runtimeLeaves.append(runtimeLeaf)

                let failureLeaf = RTSToolMetricResult(
                    identifier: UUID().uuidString,
                    resultName: "\(toolFailure.name)/\(tool.name)",
                    metricId: toolFailure.identifier,
                    agentDataId: [agentDataId],
                    value: .number(tool.status == .failed ? 1 : 0),
                    toolName: tool.name,
                    toolNodeId: tool.id.uuidString
                )
                metricResults.append(.tool(failureLeaf))
                builder.add(.tool(failureLeaf))
            }
        }

        // Phase 1 (cont.) — per-(run, tool) FailureRate and UsageCount leaves.
        for (key, count) in usage {
            let rate = count > 0 ? Double(failures[key] ?? 0) / Double(count) : 0.0
            let rateLeaf = RTSToolMetricResult(
                identifier: UUID().uuidString,
                resultName: "\(failureRate.name)/\(key.toolName)",
                metricId: failureRate.identifier,
                agentDataId: [key.agentDataId],
                value: .number(rate),
                toolName: key.toolName,
                toolNodeId: nil
            )
            metricResults.append(.tool(rateLeaf))
            builder.add(.tool(rateLeaf))
            failureRateLeaves.append(rateLeaf)

            let countLeaf = RTSToolMetricResult(
                identifier: UUID().uuidString,
                resultName: "\(usageCount.name)/\(key.toolName)",
                metricId: usageCount.identifier,
                agentDataId: [key.agentDataId],
                value: .number(Double(count)),
                toolName: key.toolName,
                toolNodeId: nil
            )
            metricResults.append(.tool(countLeaf))
            builder.add(.tool(countLeaf))
            usageCountLeaves.append(countLeaf)
        }

        // Phase 2 — per-run Runtime aggregates, grouped by (run, tool).
        var runtimeGroups: [ToolKey: [RTSToolMetricResult]] = [:]
        for leaf in runtimeLeaves {
            let key = ToolKey(agentDataId: leaf.agentDataId.first ?? "", toolName: leaf.toolName)
            runtimeGroups[key, default: []].append(leaf)
        }
        var perRunRuntimeAggIds: [String: [String]] = [:]   // toolName -> [per-run aggregate id]
        for (key, leaves) in runtimeGroups {
            let id = addToolAggregate(
                metric: runtime,
                toolName: key.toolName,
                children: leaves.map { $0.identifier },
                into: &builder
            )
            perRunRuntimeAggIds[key.toolName, default: []].append(id)
        }

        // Phase 3 — cross-run FailureRate/UsageCount aggregates, and the cross-run Runtime parent.
        aggregateByTool(metric: failureRate, leaves: failureRateLeaves, into: &builder)
        aggregateByTool(metric: usageCount, leaves: usageCountLeaves, into: &builder)
        for (toolName, childIds) in perRunRuntimeAggIds {
            _ = addToolAggregate(metric: runtime, toolName: toolName, children: childIds, into: &builder)
        }

        let result = RTSEvaluatorResult(
            evaluatorName: name,
            evaluatorId: identifier,
            metricResults: metricResults,
            aggregateResults: builder.build()
        )
        return RTSEvaluatorOutput(
            result: result,
            metrics: [.numerical(toolFailure), .numerical(runtime),
                      .numerical(failureRate), .numerical(usageCount)]
        )
    }

    /// Group leaves by tool name and add one aggregate per tool (each a root).
    private func aggregateByTool(
        metric: RTSNumericalMetric,
        leaves: [RTSToolMetricResult],
        into builder: inout RTSForestBuilder
    ) {
        var groups: [String: [RTSToolMetricResult]] = [:]
        for leaf in leaves {
            groups[leaf.toolName, default: []].append(leaf)
        }
        for (toolName, groupLeaves) in groups {
            _ = addToolAggregate(
                metric: metric,
                toolName: toolName,
                children: groupLeaves.map { $0.identifier },
                into: &builder
            )
        }
    }

    /// Materialize a tool aggregate over the given children, add it as a root, and return its id.
    private func addToolAggregate(
        metric: RTSNumericalMetric,
        toolName: String,
        children: [String],
        into builder: inout RTSForestBuilder
    ) -> String {
        let values = builder.numericValues(ofChildren: children)
        let stats = RTSAggregateStats.numeric(values)
        let node = RTSToolAggregate(
            identifier: UUID().uuidString,
            type: "ToolAggregate",
            name: "Aggregate/\(metric.name)",
            metric: .numerical(metric),
            children: children,
            toolName: toolName,
            values: values,
            mean: stats.mean,
            minimum: stats.minimum,
            maximum: stats.maximum,
            median: stats.median,
            std: stats.std,
            mode: stats.mode
        )
        builder.add(.toolAggregate(node))
        builder.addRoot(node.identifier)
        return node.identifier
    }
}
