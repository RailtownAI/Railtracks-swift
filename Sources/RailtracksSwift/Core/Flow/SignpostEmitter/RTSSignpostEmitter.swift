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
/// `AgentRunHandle` map needed to pair interval begin/end calls.
final class RTSSignpostEmitter: RTSSignpostEmitting, @unchecked Sendable {

    private let lock = NSLock()
    private var handles: [UUID: AgentRunHandle] = [:]

    // MARK: - Interval

    func emitNodeStart(
        nodeID: UUID,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: UUID,
        input: RTSInput
    ) {
        guard nodeType == .agent else { return }
        let event = AgentRun(
            name: nodeName,
            nodeId: nodeID.uuidString,
            sessionId: sessionID.uuidString,
            runId: sessionID.uuidString,
            parentName: parentName
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
        runID: UUID,
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
        startTime: TimeInterval
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
            name: name,
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
        startTime: TimeInterval
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
            toolName: toolName,
            content: truncatedContent,
            startTime: startTime
        )
        log.trace("🚧 emitting io: \(io)")
        RailtracksSignposts.emit(io)
    }
}

private extension RTSFlowNodeType {
    var asNodeType: NodeType {
        switch self {
        case .agent: return .agent
        case .tool:  return .tool
        }
    }
}
