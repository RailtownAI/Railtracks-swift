//
//  RTSAgentDataPoint.swift
//  RailtracksSwift
//

import Foundation

/// Role of a single LLM message.
public enum RTSEvalMessageRole: String, Sendable {
    case system, assistant, user, tool
}

/// A tool call's inputs: positional `args` and keyword `kwargs`.
public struct RTSToolArguments: Sendable {
    public let args: [RTSValue]
    public let kwargs: [String: RTSValue]
}

/// One tool invocation made by an agent (derived from an outgoing trace edge).
public struct RTSEvalToolCall: Sendable {
    public let id: UUID
    public let name: String
    public let arguments: RTSToolArguments
    public let output: RTSValue
    public let runtime: Double?
    /// The traced execution status of this call (from the trace edge), not an evaluation verdict.
    public let status: RTSFlowStatus
}

/// One message flowing into or out of an LLM call.
public struct RTSLLMIO: Sendable {
    public let role: RTSEvalMessageRole
    public let content: RTSValue
}

/// One LLM round within an agent execution (model, messages, tokens, cost, latency).
public struct RTSLLMCall: Sendable {
    public let modelName: String
    public let modelProvider: String
    public let input: [RTSLLMIO]
    public let output: RTSLLMIO
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalCost: Double?
    public let latency: Double?
    public let index: Int
}

/// One agent execution — the unit evaluators consume.
public struct RTSAgentDataPoint: Sendable {
    /// Per-execution node id (from the trace).
    public let id: UUID
    public let sessionID: UUID
    public let agentName: String
    public let agentInput: RTSValue
    public let agentOutput: RTSValue
    public let llmCalls: [RTSLLMCall]
    public let toolNames: Set<String>
    public let toolCalls: [RTSEvalToolCall]
    /// Trace-independent bag for post-ingestion annotations (e.g. an "expected"
    /// value for a future expectation-aware judge). Never populated by ingestion.
    public var metadata: [String: RTSValue]

    public init(
        id: UUID,
        sessionID: UUID,
        agentName: String,
        agentInput: RTSValue,
        agentOutput: RTSValue,
        llmCalls: [RTSLLMCall],
        toolNames: Set<String>,
        toolCalls: [RTSEvalToolCall],
        metadata: [String: RTSValue] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentName = agentName
        self.agentInput = agentInput
        self.agentOutput = agentOutput
        self.llmCalls = llmCalls
        self.toolNames = toolNames
        self.toolCalls = toolCalls
        self.metadata = metadata
    }

    /// Stable cross-run agent identity: deterministic hash of the agent name
    /// (Python groups by raw name; a deterministic hash is 1:1-equivalent and gives
    /// a stable id). Internal grouping key — not emitted in the report.
    public var agentID: String {
        RailtracksSwift.equalityHash(agentName)
    }
}
