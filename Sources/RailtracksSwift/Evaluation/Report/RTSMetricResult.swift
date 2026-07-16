//
//  RTSMetricResult.swift
//  RailtracksSwift
//

import Foundation

// MARK: - Base

/// A generic leaf measurement (`type` "Base"); `value` is often a categorical judge label.
@EncodeNulls
public struct RTSBaseMetricResult: Codable, Sendable {
    public let identifier: String
    public let type: String            // "Base"
    public let resultName: String
    public let metricId: String
    public let agentDataId: [String]
    public let value: RTSValue

    public init(
        identifier: String,
        type: String = "Base",
        resultName: String,
        metricId: String,
        agentDataId: [String],
        value: RTSValue
    ) {
        self.identifier = identifier
        self.type = type
        self.resultName = resultName
        self.metricId = metricId
        self.agentDataId = agentDataId
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case identifier, type
        case resultName = "result_name"
        case metricId = "metric_id"
        case agentDataId = "agent_data_id"
        case value
    }
}

// MARK: - Tool

/// A leaf measurement for a tool metric (`type` "Tool"); adds the tool it measured.
@EncodeNulls
public struct RTSToolMetricResult: Codable, Sendable {
    public let identifier: String
    public let type: String            // "Tool"
    public let resultName: String
    public let metricId: String
    public let agentDataId: [String]
    public let value: RTSValue
    public let toolName: String
    public let toolNodeId: String?

    public init(
        identifier: String,
        type: String = "Tool",
        resultName: String,
        metricId: String,
        agentDataId: [String],
        value: RTSValue,
        toolName: String,
        toolNodeId: String? = nil
    ) {
        self.identifier = identifier
        self.type = type
        self.resultName = resultName
        self.metricId = metricId
        self.agentDataId = agentDataId
        self.value = value
        self.toolName = toolName
        self.toolNodeId = toolNodeId
    }

    enum CodingKeys: String, CodingKey {
        case identifier, type
        case resultName = "result_name"
        case metricId = "metric_id"
        case agentDataId = "agent_data_id"
        case value
        case toolName = "tool_name"
        case toolNodeId = "tool_node_id"
    }
}

// MARK: - LLM

/// A leaf measurement for an LLM-inference metric (`type` "LLM"); adds the call/model it measured.
@EncodeNulls
public struct RTSLLMMetricResult: Codable, Sendable {
    public let identifier: String
    public let type: String            // "LLM"
    public let resultName: String
    public let metricId: String
    public let agentDataId: [String]
    public let value: RTSValue
    public let llmCallIndex: Int
    public let modelName: String
    public let modelProvider: String

    public init(
        identifier: String,
        type: String = "LLM",
        resultName: String,
        metricId: String,
        agentDataId: [String],
        value: RTSValue,
        llmCallIndex: Int,
        modelName: String,
        modelProvider: String
    ) {
        self.identifier = identifier
        self.type = type
        self.resultName = resultName
        self.metricId = metricId
        self.agentDataId = agentDataId
        self.value = value
        self.llmCallIndex = llmCallIndex
        self.modelName = modelName
        self.modelProvider = modelProvider
    }

    enum CodingKeys: String, CodingKey {
        case identifier, type
        case resultName = "result_name"
        case metricId = "metric_id"
        case agentDataId = "agent_data_id"
        case value
        case llmCallIndex = "llm_call_index"
        case modelName = "model_name"
        case modelProvider = "model_provider"
    }
}

// MARK: - Polymorphic metric result

/// A single leaf measurement, serialized polymorphically on the `type` discriminator:
/// "Tool" → `RTSToolMetricResult`, "LLM" → `RTSLLMMetricResult`, else `RTSBaseMetricResult`.
/// `value` is String | number | null (modeled with `RTSValue`).
public enum RTSMetricResult: Codable, Sendable {
    case tool(RTSToolMetricResult)
    case llm(RTSLLMMetricResult)
    case base(RTSBaseMetricResult)

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "Tool": self = .tool(try RTSToolMetricResult(from: decoder))
        case "LLM":  self = .llm(try RTSLLMMetricResult(from: decoder))
        default:     self = .base(try RTSBaseMetricResult(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .tool(let result): try result.encode(to: encoder)
        case .llm(let result):  try result.encode(to: encoder)
        case .base(let result): try result.encode(to: encoder)
        }
    }
}
