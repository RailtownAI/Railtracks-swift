//
//  RTSSignpostEmitter.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation
import RailtracksInstrumentationKit

// TODO: RTSSignpostEmitter and RTSSignpostEmitting can be migrated to a separate
// RailtracksSwiftInstruments target so RailtracksInstrumentationKit is an optional
// dependency rather than required for all RailtracksSwift consumers.

/// Default `RTSSignpostEmitting` conformer. Routes each call directly to the
/// matching `RailtracksSignposts` API — no internal state except the
/// `NodeRunHandle` map needed to pair interval begin/end calls. Every node call
/// (agent, tool, function) gets a Node Runs interval nested under its caller's.
final class RTSSignpostEmitter: RTSSignpostEmitting, @unchecked Sendable {

    private let lock = NSLock()
    private var handles: [RTSRunID: NodeRunHandle] = [:]

    // MARK: - Interval

    func emitNodeStart(
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        input: RTSInput,
        instructions: String?,
        hasInputGuardrail: Bool = false,
        hasOutputGuardrail: Bool = false
    ) {
        let event = NodeRun(
            name: Self.decorateWithGuardrails(
                nodeName,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            ),
            nodeType: nodeType.asNodeType,
            nodeId: nodeID.uuidString,
            parentNodeId: parentNodeID?.uuidString ?? "",
            sessionId: sessionID.uuidString,
            runId: sessionID.uuidString,
            parentName: parentName,
            input: Self.inputSummary(input, nodeType: nodeType),
            instructions: instructions ?? ""
        )
        let handle = RailtracksSignposts.begin(event)
        log.trace("🚧 emitting begin: \(event) | \(handle)")
        lock.withLock { handles[runID] = handle }
    }

    func emitNodeEnd(
        nodeID: UUID,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        output: RTSOutput?,
        error: Error?
    ) {
        guard let handle = lock.withLock({ handles.removeValue(forKey: runID) }) else { return }
        log.trace("🚧 emitting end: \(handle)")
        RailtracksSignposts.end(handle, error: error != nil)
    }

    // MARK: - Point events

    func emitGraphNode(
        nodeID: String,
        parentID: String,
        sessionID: String,
        runID: String,
        nodeType: RTSFlowNodeType,
        parentType: RTSFlowNodeType?,
        error: Bool,
        parentError: Bool,
        cost: Double,
        model: String,
        parentName: String,
        name: String,
        startTime: TimeInterval
    ) {
        let graphNode = FlowGraphNode(
            nodeId: nodeID,
            parentId: parentID,
            sessionId: sessionID,
            runId: runID,
            nodeType: nodeType.asNodeType,
            parentType: parentType?.asNodeType,
            error: error,
            parentError: parentError,
            cost: cost,
            model: model,
            parentName: parentName,
            name: name,
            startTime: startTime
        )
        log.trace("🚧 emitting graphNode: \(graphNode)")
        RailtracksSignposts.emit(graphNode)
    }

    func emitTreeNode(
        nodeID: String,
        sessionID: String,
        runID: String,
        nodeType: RTSFlowNodeType,
        model: String,
        provider: String,
        cost: Double,
        latency: Double,
        inputTokens: Int,
        outputTokens: Int,
        error: Bool,
        ancestors: [String],
        name: String,
        startTime: TimeInterval,
        hasInputGuardrail: Bool = false,
        hasOutputGuardrail: Bool = false
    ) {
        let treeNode = FlowTreeNode(
            nodeId: nodeID,
            sessionId: sessionID,
            runId: runID,
            nodeType: nodeType.asNodeType,
            model: model,
            provider: provider,
            cost: cost,
            latency: latency,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            error: error,
            ancestors: ancestors,
            name: Self.decorateWithGuardrails(
                name,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            ),
            startTime: startTime
        )
        log.trace("🚧 emitting treeNode: \(treeNode)")
        RailtracksSignposts.emit(treeNode)
    }

    func emitIO(
        nodeID: String,
        sessionID: String,
        runID: String,
        messageID: String,
        source: String,
        direction: String,
        role: String,
        model: String,
        provider: String,
        cost: Double,
        latency: Double,
        inputTokens: Int,
        outputTokens: Int,
        displayRole: String,
        toolName: String,
        content: String,
        startTime: TimeInterval,
        hasInputGuardrail: Bool = false,
        hasOutputGuardrail: Bool = false
    ) {
        let limit = RailtracksSwift.signpostIOContentLimit
        let truncatedContent = content.count > limit
            ? String(content.prefix(limit)) + "…"
            : content
        let io = FlowIO(
            nodeId: nodeID,
            sessionId: sessionID,
            runId: runID,
            messageId: messageID,
            source: source,
            direction: direction,
            role: role,
            model: model,
            provider: provider,
            cost: cost,
            latency: latency,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            displayRole: displayRole,
            toolName: Self.decorateWithGuardrails(
                toolName,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            ),
            content: truncatedContent,
            startTime: startTime
        )
        log.trace("🚧 emitting io: \(io)")
        RailtracksSignposts.emit(io)
    }
    
    /// Rough ceiling on the summary text built here. The kit collapses whitespace and caps the
    /// published value far below this; the limit only stops a huge input from being rendered in full.
    static let inputSummaryLimit = 4096

    /// Short text for the Node Runs hover: what the node received. For an agent, the prompt it sends
    /// as its user message (plus a placeholder per attached image), derived by `RTSAgentInput` the way
    /// `RTSAgentNode.invoke` does; an agent input without a prompt falls back to the key/value form.
    /// For tools and functions, `key: value` pairs in key order, each value rendered as the Tool I/O
    /// lane renders it. Empty input gives `""`.
    static func inputSummary(_ input: RTSInput, nodeType: RTSFlowNodeType) -> String {
        if nodeType == .agent, let prompt = RTSAgentInput.prompt(in: input) {
            let images = RTSAgentInput.images(in: input).map(RTSValue.imagePlaceholder)
            return ([String(prompt.prefix(inputSummaryLimit))] + images).joined(separator: " ")
        }
        var summary = ""
        for key in input.keys.sorted() {
            if summary.utf8.count > inputSummaryLimit {
                summary += "…"
                break
            }
            if !summary.isEmpty {
                summary += ", "
            }
            summary += "\(key): \((input[key] ?? .null).signpostText)"
        }
        return summary
    }

    /// Instruments-only decoration: a shield (⛨, BLACK CROSS ON SHIELD) is suffixed when
    /// the agent has any guardrails (input or output), giving a quick visual cue across
    /// the Node Runs, Flow Tree, and Tool I/O lanes. Applied here (not to the node's real
    /// name) so the JSON trace keeps the undecorated name.
    private static func decorateWithGuardrails(
        _ name: String,
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    ) -> String {
        let shield = "⛨"
        return name + ((hasInputGuardrail || hasOutputGuardrail) ? " \(shield)" : "")
    }
}

private extension RTSFlowNodeType {
    var asNodeType: NodeType {
        switch self {
        case .agent:
            return .agent
        case .tool:
            return .tool
        case .function:
            return .custom(rawValue)
        }
    }
}
