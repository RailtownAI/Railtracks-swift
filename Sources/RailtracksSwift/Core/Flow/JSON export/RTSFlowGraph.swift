//
//  RTSFlowGraph.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-12.
//

import Foundation

// MARK: - RTSFlowGraph

/// A structure representation of JSON output that can by consumed by python visualizer
@EncodeNulls
public struct RTSFlowGraph: Codable {
    /// Name of the flow
    public let flowName: String
    /// A hashed value of flowName, will be the same if flowName is the same
    public let flowID: String
    /// Representing per run of the flow, effectively the ID for this flow.
    /// Session here is unrelated to session used to communicate with LLM.
    public let sessionID: String
    /// Tech debt from python, will be null for now
    /// Session here is unrelated to session used to communicate with LLM.
    public let sessionName: String?
    /// Start time of the flow's execution
    public let startTime: TimeInterval
    /// End time of the flow's completion
    public let endTime: TimeInterval
    /// By existing design runs will only have one item in the array and is corresponding to sessionID
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

/// A sub-structure representation of JSON output that can by consumed by python visualizer
public struct RTSFlowRun: Codable {
    public let name: String
    /// ID for the run, will be represented by rootNode's runID
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

public enum RTSFlowStatus: String, Codable, Sendable {
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

@EncodeNulls
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
@EncodeNulls
public struct RTSFlowGraphNodeCreation: Codable {
    public let identifier: String
    public let nodeType: RTSFlowNodeType
    public let name: String
    public let stamp: RTSFlowGraphStamp
    public let details: RTSFlowGraphNodeDetails
    /// Always null — added to mirror the JSON schema where creation snapshots carry a null parent.
    private let parent: String? = nil

    enum CodingKeys: String, CodingKey {
        case identifier
        case nodeType = "node_type"
        case name, stamp, details, parent
    }

}

// MARK: - RTSFlowNodeType

public enum RTSFlowNodeType: String, Sendable {
    case agent = "Agent"
    case tool = "Tool"
    /// A function/orchestrator node — deterministic code that may invoke agents.
    case function = "Function"
}

extension RTSFlowNodeType: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RTSFlowNodeType(rawValue: raw) ?? .tool
    }

    /// `.function` is serialized as `"Tool"`: the visualizer only renders `Agent`/`Tool`
    /// graph nodes (it filters everything else out), and Python's function nodes serialize
    /// as `"Tool"` as well. `.function` stays the internal type — it still drives edge-output
    /// and signpost handling; only the on-the-wire value maps to `"Tool"`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .function:
            try container.encode(RTSFlowNodeType.tool.rawValue)
        case .agent, .tool:
            try container.encode(rawValue)
        }
    }
}

// MARK: - RTSFlowGraphNodeDetails

public struct RTSFlowGraphNodeDetails: Codable {
    public let internals: RTSFlowGraphNodeInternals
}

// MARK: - RTSFlowGraphNodeInternals

public struct RTSFlowGraphNodeInternals: Codable {
    public let llmDetails: [RTSFlowGraphLLMDetail]?
    public let latency: RTSFlowGraphLatency?
    public let guardDetails: [RTSGuardrailTrace]?

    enum CodingKeys: String, CodingKey {
        case llmDetails = "llm_details"
        case latency
        case guardDetails = "guard_details"
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

@EncodeNulls
public struct RTSFlowGraphEdge: Codable {
    public let source: String?
    public let target: String
    public let identifier: String
    public let stamp: RTSFlowGraphStamp
    public let details: RTSFlowGraphEdgeDetails
    public let parent: RTSFlowGraphEdgeCreation?

    enum CodingKeys: String, CodingKey {
        case source, target, identifier, stamp, details, parent
    }

}

// MARK: - RTSFlowGraphEdgeCreation

/// Flat creation-time snapshot of an edge, used as the parent reference.
/// Mirrors RTSFlowGraphEdge without the recursive parent field.
@EncodeNulls
public struct RTSFlowGraphEdgeCreation: Codable {
    public let source: String?
    public let target: String
    public let identifier: String
    public let stamp: RTSFlowGraphStamp
    public let details: RTSFlowGraphEdgeDetails
    /// Always null — added to mirror the JSON schema where creation snapshots carry a null parent.
    private let parent: String? = nil

    enum CodingKeys: String, CodingKey {
        case source, target, identifier, stamp, details, parent
    }

}

// MARK: - RTSFlowGraphEdgeDetails

public enum RTSEdgeOutput: Sendable {
    case structured(RTSGeneratedContent?)
    case agentStatus(String)
}

public struct RTSFlowGraphEdgeDetails: Codable {
    public let inputArgs: [String]
    public let inputKwargs: [String: RTSGeneratedContent]
    public let status: RTSFlowStatus
    public let output: RTSEdgeOutput

    public init(inputArgs: [String], inputKwargs: [String: RTSGeneratedContent], status: RTSFlowStatus, output: RTSEdgeOutput) {
        self.inputArgs = inputArgs
        self.inputKwargs = inputKwargs
        self.status = status
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case inputArgs = "input_args"
        case inputKwargs = "input_kwargs"
        case status, output
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputArgs, forKey: .inputArgs)
        try container.encode(inputKwargs, forKey: .inputKwargs)
        try container.encode(status, forKey: .status)
        switch output {
        case .structured(let content):
            try container.encode(content, forKey: .output)
        case .agentStatus(let string):
            try container.encode(string, forKey: .output)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputArgs = try container.decode([String].self, forKey: .inputArgs)
        inputKwargs = try container.decode([String: RTSGeneratedContent].self, forKey: .inputKwargs)
        status = try container.decode(RTSFlowStatus.self, forKey: .status)
        output = .structured(try container.decodeIfPresent(RTSGeneratedContent.self, forKey: .output))
    }
}

// MARK: - RTSGeneratedContent

public struct RTSGeneratedContent: Sendable, Codable {
    public enum Kind: Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([RTSGeneratedContent])
        case structure([String: RTSGeneratedContent])
    }
    public let kind: Kind

    public init(from decoder: Decoder) throws {
        let singleContainer = try? decoder.singleValueContainer()
        if singleContainer?.decodeNil() == true { kind = .null; return }
        if let bool = try? singleContainer?.decode(Bool.self)     { kind = .bool(bool); return }
        if let number = try? singleContainer?.decode(Double.self) { kind = .number(number); return }
        if let string = try? singleContainer?.decode(String.self) { kind = .string(string); return }
        if var unkeyedContainer = try? decoder.unkeyedContainer() {
            var elements: [RTSGeneratedContent] = []
            while !unkeyedContainer.isAtEnd {
                elements.append(try unkeyedContainer.decode(RTSGeneratedContent.self))
            }
            kind = .array(elements); return
        }
        let keyedContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        kind = .structure(try keyedContainer.allKeys.reduce(into: [:]) {
            $0[$1.stringValue] = try keyedContainer.decode(RTSGeneratedContent.self, forKey: $1)
        })
    }

    public func encode(to encoder: Encoder) throws {
        switch kind {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .array(let elements):
            var container = encoder.unkeyedContainer()
            for element in elements { try container.encode(element) }
        case .structure(let props):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in props { try container.encode(value, forKey: AnyCodingKey(key)) }
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
