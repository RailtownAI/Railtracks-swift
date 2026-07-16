//
//  RTSEvaluationReport.swift
//  RailtracksSwift
//

import Foundation

// MARK: - Agent references

/// A reference to one agent execution: which session, and which agent node within it.
@EncodeNulls
public struct RTSAgentNodeRef: Codable, Sendable {
    public let sessionId: String
    public let agentNodeId: String

    public init(sessionId: String, agentNodeId: String) {
        self.sessionId = sessionId
        self.agentNodeId = agentNodeId
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentNodeId = "agent_node_id"
    }
}

/// One evaluated agent (by name) and the list of its executions across sessions/runs.
@EncodeNulls
public struct RTSReportAgent: Codable, Sendable {
    public let agentName: String
    public let agentNodeIds: [RTSAgentNodeRef]

    public init(agentName: String, agentNodeIds: [RTSAgentNodeRef]) {
        self.agentName = agentName
        self.agentNodeIds = agentNodeIds
    }

    enum CodingKeys: String, CodingKey {
        case agentName = "agent_name"
        case agentNodeIds = "agent_node_ids"
    }
}

// MARK: - Evaluator result

/// The output of one evaluator for one agent: its flat metric results plus the aggregate forest.
@EncodeNulls
public struct RTSEvaluatorResult: Codable, Sendable {
    public let evaluatorName: String
    public let evaluatorId: String
    public let metricResults: [RTSMetricResult]
    public let aggregateResults: RTSAggregateForest

    public init(
        evaluatorName: String,
        evaluatorId: String,
        metricResults: [RTSMetricResult],
        aggregateResults: RTSAggregateForest
    ) {
        self.evaluatorName = evaluatorName
        self.evaluatorId = evaluatorId
        self.metricResults = metricResults
        self.aggregateResults = aggregateResults
    }

    enum CodingKeys: String, CodingKey {
        case evaluatorName = "evaluator_name"
        case evaluatorId = "evaluator_id"
        case metricResults = "metric_results"
        case aggregateResults = "aggregate_results"
    }
}

// MARK: - Report root

/// Root of the evaluation report JSON — one per agent. Mirrors the Python `EvaluationResult`
/// schema consumed by the Python visualizer.
///
/// Component graph:
/// ```
/// RTSEvaluationReport                          ← root (per agent)
/// ├─ createdAt / completedAt : RTSISODate
/// ├─ agents          : [RTSReportAgent]
/// │                      └─ agentNodeIds : [RTSAgentNodeRef]  {session_id, agent_node_id}
/// ├─ metricsMap      : [String: RTSMetric]      (the metric descriptors)
/// └─ evaluatorResults: [RTSEvaluatorResult]
///                        ├─ metricResults    : [RTSMetricResult]   (leaves)
///                        └─ aggregateResults : RTSAggregateForest
///                                               └─ nodes: [String: RTSAggregateNode]
///                                                          (leaves reuse RTSMetricResult shapes;
///                                                           aggregates nest RTSMetric)
/// ```
@EncodeNulls
public struct RTSEvaluationReport: Codable, Sendable {
    public let evaluationId: String
    public let createdAt: RTSISODate
    public let completedAt: RTSISODate
    public let evaluationName: String?
    public let agents: [RTSReportAgent]
    public let metricsMap: [String: RTSMetric]
    public let evaluatorResults: [RTSEvaluatorResult]

    public init(
        evaluationId: String,
        createdAt: RTSISODate,
        completedAt: RTSISODate,
        evaluationName: String?,
        agents: [RTSReportAgent],
        metricsMap: [String: RTSMetric],
        evaluatorResults: [RTSEvaluatorResult]
    ) {
        self.evaluationId = evaluationId
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.evaluationName = evaluationName
        self.agents = agents
        self.metricsMap = metricsMap
        self.evaluatorResults = evaluatorResults
    }

    enum CodingKeys: String, CodingKey {
        case evaluationId = "evaluation_id"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case evaluationName = "evaluation_name"
        case agents
        case metricsMap = "metrics_map"
        case evaluatorResults = "evaluator_results"
    }
}
