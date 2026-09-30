//
//  RTSSignpostEmitting.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation

/// Implement this protocol to receive signpost events from the pipeline.
/// Inject a conformer into `RTSFlow.init` to enable Instruments tracing without
/// coupling RailtracksSwift to any specific instrumentation library.
///
/// `RTSNodeInvoker` calls `emitNodeStart`/`emitNodeEnd` in real time at execution
/// boundaries — suitable for interval signposts. `RTSFlowGraphCollector` calls the
/// four point-event methods from within its publisher receive closures, so messages
/// are already attached and the full ancestor chain is derivable from accumulated
/// edge events.
public protocol RTSSignpostEmitting: Sendable {

    // MARK: - Interval (called by RTSNodeInvoker, real-time)

    /// Called when a node call (agent, tool, function) begins, once per invocation.
    /// - Parameters:
    ///   - nodeID: This invocation's id, distinct per call even when the same node runs twice.
    ///   - parentNodeID: The calling node's invocation id, or `nil` at the flow root. Lets a
    ///     conformer nest the call under its caller's interval.
    func emitNodeStart(
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        input: RTSInput,
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    )
    
    func emitNodeEnd(
        nodeID: UUID,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        output: RTSOutput?,
        error: Error?
    )

    // MARK: - Point events (called by RTSFlowGraphCollector, with complete data)

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
    )

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
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    )

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
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    )
}
