//
//  RTSSignpostEmitter.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation
import RailtracksInstrumentationKit

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
            runId: runID.uuidString,
            parentName: parentName
        )
        let handle = RailtracksSignposts.begin(event)
        log.trace("🚧 emitting begin: \(event) | \(handle)")
        lock.withLock { handles[nodeID] = handle }
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
        guard let handle = lock.withLock({ handles.removeValue(forKey: nodeID) }) else { return }
        log.trace("🚧 emitting end: \(handle)")
        RailtracksSignposts.end(handle, error: error != nil)
    }

    // MARK: - Point events

    func emitGraphNode(
        nodeID: String,
        parentID: String,
        sessionID: String,
        runID: String,
        nodeType: String,
        parentType: String,
        error: Bool,
        parentError: Bool,
        cost: Double,
        model: String,
        parentName: String,
        name: String
    ) {
        let graphNode = FlowGraphNode(
            nodeId: nodeID,
            parentId: parentID,
            sessionId: sessionID,
            runId: runID,
            nodeType: nodeType,
            parentType: parentType,
            error: error,
            parentError: parentError,
            cost: cost,
            model: model,
            parentName: parentName,
            name: name
        )
        log.trace("🚧 emitting graphNode: \(graphNode)")
        RailtracksSignposts.emit(graphNode)
    }

    func emitTreeNode(
        nodeID: String,
        sessionID: String,
        runID: String,
        nodeType: String,
        model: String,
        provider: String,
        cost: Double,
        latency: Double,
        inputTokens: Int,
        outputTokens: Int,
        error: Bool,
        ancestors: [String],
        name: String
    ) {
        let treeNode = FlowTreeNode(
            nodeId: nodeID,
            sessionId: sessionID,
            runId: runID,
            nodeType: nodeType,
            model: model,
            provider: provider,
            cost: cost,
            latency: latency,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            error: error,
            ancestors: ancestors,
            name: name
        )
        log.trace("🚧 emitting treeNode: \(treeNode)")
        RailtracksSignposts.emit(treeNode)
    }

    func emitEdge(
        source: String,
        target: String,
        runID: String
    ) {
        let edge = FlowEdge(source: source, target: target, runId: runID)
        log.trace("🚧 emitting edge: \(edge)")
        RailtracksSignposts.emit(edge)
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
        content: String
    ) {
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
            content: content
        )
        log.trace("🚧 emitting io: \(io)")
        RailtracksSignposts.emit(io)
    }
}
