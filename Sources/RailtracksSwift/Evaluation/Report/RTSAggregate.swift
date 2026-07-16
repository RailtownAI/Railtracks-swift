//
//  RTSAggregate.swift
//  RailtracksSwift
//

import Foundation

// MARK: - Numeric aggregate (Tool)

/// A per-tool numeric aggregate node with materialized stats over its descendant values.
@EncodeNulls
public struct RTSToolAggregate: Codable, Sendable {
    public let identifier: String
    public let type: String            // "ToolAggregate"
    public let name: String
    public let metric: RTSMetric
    public let children: [String]
    public let toolName: String
    public let values: [Double]
    public let mean: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let median: Double?
    public let std: Double?
    public let mode: Double?

    enum CodingKeys: String, CodingKey {
        case identifier, type, name, metric, children
        case toolName = "tool_name"
        case values, mean, minimum, maximum, median, std, mode
    }
}

// MARK: - Numeric aggregate (LLM inference)

/// A numeric aggregate node grouped by (model, provider, call index) with materialized stats.
@EncodeNulls
public struct RTSLLMInferenceAggregate: Codable, Sendable {
    public let identifier: String
    public let type: String            // "LLMInferenceAggregate"
    public let name: String
    public let metric: RTSMetric
    public let children: [String]
    public let llmCallIndex: Int
    public let modelName: String
    public let modelProvider: String
    public let values: [Double]
    public let mean: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let median: Double?
    public let std: Double?
    public let mode: Double?

    enum CodingKeys: String, CodingKey {
        case identifier, type, name, metric, children
        case llmCallIndex = "llm_call_index"
        case modelName = "model_name"
        case modelProvider = "model_provider"
        case values, mean, minimum, maximum, median, std, mode
    }
}

// MARK: - Categorical aggregate

/// A categorical aggregate node: label `counts` over its descendants plus most/least common.
@EncodeNulls
public struct RTSCategoricalAggregate: Codable, Sendable {
    public let identifier: String
    public let type: String            // "CategoricalAggregate"
    public let name: String
    public let metric: RTSMetric
    public let children: [String]
    public let categories: [String]
    public let counts: [String: Int]
    public let mostCommonLabel: String?
    public let leastCommonLabel: String?

    enum CodingKeys: String, CodingKey {
        case identifier, type, name, metric, children, categories, counts
        case mostCommonLabel = "most_common_label"
        case leastCommonLabel = "least_common_label"
    }
}

// MARK: - Polymorphic forest node (6 shapes)

/// A node in the aggregate forest — either a leaf measurement (same shapes as
/// `RTSMetricResult`) or an aggregate node — discriminated by `type`.
public enum RTSAggregateNode: Codable, Sendable {
    // Leaves (identical shapes to RTSMetricResult variants)
    case tool(RTSToolMetricResult)
    case llm(RTSLLMMetricResult)
    case base(RTSBaseMetricResult)
    // Aggregates
    case toolAggregate(RTSToolAggregate)
    case llmAggregate(RTSLLMInferenceAggregate)
    case categoricalAggregate(RTSCategoricalAggregate)

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self)
            .decode(String.self, forKey: .type)
        switch type {
        case "Tool":
            self = .tool(try RTSToolMetricResult(from: decoder))
        case "LLM":
            self = .llm(try RTSLLMMetricResult(from: decoder))
        case "ToolAggregate":
            self = .toolAggregate(try RTSToolAggregate(from: decoder))
        case "LLMInferenceAggregate":
            self = .llmAggregate(try RTSLLMInferenceAggregate(from: decoder))
        case "CategoricalAggregate":
            self = .categoricalAggregate(try RTSCategoricalAggregate(from: decoder))
        default:
            self = .base(try RTSBaseMetricResult(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .tool(let node):                 try node.encode(to: encoder)
        case .llm(let node):                  try node.encode(to: encoder)
        case .base(let node):                 try node.encode(to: encoder)
        case .toolAggregate(let node):        try node.encode(to: encoder)
        case .llmAggregate(let node):         try node.encode(to: encoder)
        case .categoricalAggregate(let node): try node.encode(to: encoder)
        }
    }
}

// MARK: - Forest

/// The aggregate forest: a flat `[id: node]` map plus top-level `roots`; trees are expressed
/// by each node's `children` id references into `nodes`.
public struct RTSAggregateForest: Codable, Sendable {
    public let roots: [String]
    public let nodes: [String: RTSAggregateNode]

    public init(roots: [String], nodes: [String: RTSAggregateNode]) {
        self.roots = roots
        self.nodes = nodes
    }
}
