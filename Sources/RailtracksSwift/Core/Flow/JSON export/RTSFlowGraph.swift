//
//  RTSFlowGraph.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-12.
//

import Foundation

// MARK: - RTSFlowGraph

public struct RTSFlowGraph: Codable {
    public let flowName: String
    public let flowID: String
    public let sessionID: String?
    public let sessionName: String?
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let runs: [RTSFlowRun]

    enum CodingKeys: String, CodingKey {
        case flowName = "flow_name"
        case flowID = "flow_id"
        case sessionID = "session_id"
        case sessionName = "session_name"
        case startTime = "start_time"
        case endTime = "end_time"
        case runs
    }
}

// MARK: - RTSFlowRun

public struct RTSFlowRun: Codable {
    public let name: String
    public let runID: String
    public let nodes: [RTSFlowGraphNode]
    public let status: RTSFlowStatus
    public let edges: [RTSFlowGraphEdge]
    public let steps: [RTSFlowGraphStamp]
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    enum CodingKeys: String, CodingKey {
        case name
        case runID = "run_id"
        case nodes, status, edges, steps
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

// MARK: - RTSFlowStatus

public enum RTSFlowStatus: String, Codable {
    case completed = "Completed"
    case open = "Open"
    case failed = "Failed"
}

// MARK: - RTSFlowGraphStamp

public struct RTSFlowGraphStamp: Codable {
    public let step: Int
    public let time: TimeInterval
    public let identifier: String
}

// MARK: - RTSFlowGraphNode

public struct RTSFlowGraphNode: Codable {
    public let identifier: String
    public let nodeType: RTSFlowNodeType
    public let name: String
    public let stamp: RTSFlowGraphStamp
    public let details: RTSFlowGraphNodeDetails
    public let parent: RTSFlowGraphNodeCreation?

    enum CodingKeys: String, CodingKey {
        case identifier
        case nodeType = "node_type"
        case name, stamp, details, parent
    }
}

// MARK: - RTSFlowGraphNodeCreation

/// Flat creation-time snapshot of a node, used as the parent reference.
/// Mirrors RTSFlowGraphNode without the recursive parent field.
public struct RTSFlowGraphNodeCreation: Codable {
    public let identifier: String
    public let nodeType: RTSFlowNodeType
    public let name: String
    public let stamp: RTSFlowGraphStamp
    public let details: RTSFlowGraphNodeDetails

    enum CodingKeys: String, CodingKey {
        case identifier
        case nodeType = "node_type"
        case name, stamp, details
    }
}

// MARK: - RTSFlowNodeType

public enum RTSFlowNodeType: String, Codable {
    case agent = "Agent"
    case tool = "Tool"
}

// MARK: - RTSFlowGraphNodeDetails

public struct RTSFlowGraphNodeDetails: Codable {
    public let internals: RTSFlowGraphNodeInternals
}

// MARK: - RTSFlowGraphNodeInternals

public struct RTSFlowGraphNodeInternals: Codable {
    public let llmDetails: [RTSFlowGraphLLMDetail]?
    public let latency: RTSFlowGraphLatency?

    enum CodingKeys: String, CodingKey {
        case llmDetails = "llm_details"
        case latency
    }
}

// MARK: - RTSFlowGraphLLMDetail

public struct RTSFlowGraphLLMDetail: Codable {
    public let modelName: String
    public let modelProvider: String
    public let input: [RTSFlowGraphMessage]
    public let output: RTSFlowGraphMessage
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalCost: Double?
    public let systemFingerprint: String?
    public let latency: TimeInterval

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case modelProvider = "model_provider"
        case input, output
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalCost = "total_cost"
        case systemFingerprint = "system_fingerprint"
        case latency
    }
}

// MARK: - RTSFlowGraphMessage

/// Lightweight role+content pair used inside llm_details.
/// Content is represented as RTSGeneratedContent to handle
/// plain strings, tool call arrays, and tool result objects.
public struct RTSFlowGraphMessage: Codable {
    public let role: String
    public let content: RTSGeneratedContent
}

// MARK: - RTSFlowGraphLatency

public struct RTSFlowGraphLatency: Codable {
    public let totalTime: TimeInterval

    enum CodingKeys: String, CodingKey {
        case totalTime = "total_time"
    }
}

// MARK: - RTSFlowGraphEdge

public struct RTSFlowGraphEdge: Codable {
    public let source: String?
    public let target: String
    public let identifier: String
    public let stamp: RTSFlowGraphStamp
    public let details: RTSFlowGraphEdgeDetails
    public let parent: RTSFlowGraphEdgeCreation?
}

// MARK: - RTSFlowGraphEdgeCreation

/// Flat creation-time snapshot of an edge, used as the parent reference.
/// Mirrors RTSFlowGraphEdge without the recursive parent field.
public struct RTSFlowGraphEdgeCreation: Codable {
    public let source: String?
    public let target: String
    public let identifier: String
    public let stamp: RTSFlowGraphStamp
    public let details: RTSFlowGraphEdgeDetails
}

// MARK: - RTSFlowGraphEdgeDetails

public struct RTSFlowGraphEdgeDetails: Codable {
    public let inputArgs: [String]
    public let inputKwargs: [String: RTSGeneratedContent]
    public let status: RTSFlowStatus
    public let output: RTSGeneratedContent?

    enum CodingKeys: String, CodingKey {
        case inputArgs = "input_args"
        case inputKwargs = "input_kwargs"
        case status, output
    }
}
