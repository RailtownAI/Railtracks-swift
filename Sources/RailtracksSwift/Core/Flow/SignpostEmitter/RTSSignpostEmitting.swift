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
/// Every method is called by the flow's signpost writer, which builds the signposts from the
/// run's observability events on the emitter's delivery queue, one call at a time per event:
/// - `emitNodeStart` when a node's guardrails are done and its body is about to run, and
///   `emitNodeEnd` when the node finishes. Both are called as the events are delivered, so an
///   interval is stamped slightly after the moment it marks, by however long delivery took.
/// - The point-event methods at `node.invocation` (the graph node) and `node.destruction` (the
///   edge I/O, then the tree node and message I/O), once the data they report is complete. The
///   tree node and message I/O are sent from a detached task, for their cost. Points carry their
///   start time as a field, so when they're sent doesn't matter.
///
/// Every call except those last two arrives on the delivery queue, shared with the trace and the
/// node statuses, so a conformer should return quickly.
public protocol RTSSignpostEmitting: Sendable {

    // MARK: - Interval (called by the signpost writer, as events are delivered)

    /// Called when a node call (agent, tool, function) begins, once per invocation.
    /// - Parameters:
    ///   - nodeID: This invocation's id, distinct per call even when the same node runs twice.
    ///   - parentNodeID: The calling node's invocation id, or `nil` at the flow root. Lets a
    ///     conformer nest the call under its caller's interval.
    ///   - input: The input the node runs with, after any input guardrails.
    ///   - instructions: For an agent, the system message it runs with (its `systemMessage`
    ///     input, after any input guardrails), or `nil` when it has none. Always `nil` for tools
    ///     and functions.
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

    // MARK: - Point events (called by the signpost writer, with complete data)

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
