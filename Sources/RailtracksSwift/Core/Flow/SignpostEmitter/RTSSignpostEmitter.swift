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

    func emitNodeStart(nodeID: UUID, nodeName: String, nodeType: RTSFlowNodeType, parentName: String, runID: UUID, input: RTSInput) {
        guard nodeType == .agent else { return }
        let event = AgentRun(
            name: nodeName,
            nodeId: nodeID.uuidString,
            runId: runID.uuidString,
            parentName: parentName
        )
        let handle = RailtracksSignposts.begin(event)
        lock.withLock { handles[runID] = handle }
    }

    func emitNodeEnd(nodeID: UUID, nodeName: String, nodeType: RTSFlowNodeType, parentName: String, runID: UUID, output: RTSOutput?, error: Error?) {
        guard let handle = lock.withLock({ handles.removeValue(forKey: runID) }) else { return }
        RailtracksSignposts.end(handle, error: error != nil)
    }

    // MARK: - Point events

    func emitGraphNode(nodeID: String, parentID: String, sessionID: String, runID: String, nodeType: String, parentType: String, error: Bool, parentError: Bool, cost: Double, model: String, parentName: String, name: String) {
        RailtracksSignposts.emit(FlowGraphNode(
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
        ))
    }

    func emitTreeNode(nodeID: String, sessionID: String, runID: String, nodeType: String, model: String, provider: String, cost: Double, latency: Double, inputTokens: Int, outputTokens: Int, error: Bool, ancestors: [String], name: String) {
        RailtracksSignposts.emit(FlowTreeNode(
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
        ))
    }

    func emitEdge(source: String, target: String, runID: String) {
        RailtracksSignposts.emit(FlowEdge(source: source, target: target, runId: runID))
    }

    func emitIO(nodeID: String, sessionID: String, runID: String, messageID: String, source: String, direction: String, role: String, model: String, provider: String, cost: Double, latency: Double, inputTokens: Int, outputTokens: Int, displayRole: String, toolName: String, content: String) {
        RailtracksSignposts.emit(FlowIO(
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
        ))
    }
}
