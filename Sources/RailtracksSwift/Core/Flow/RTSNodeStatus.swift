//
//  RTSNodeStatus.swift
//  RailtracksSwift
//

import Foundation

/// Emitted by `RTSFlow.nodeStatusPublisher` as each node transitions through its lifecycle.
///
/// A UI-facing projection of the invoker's events, entirely separate from the trace:
/// `RTSFlowGraphCollector` subscribes to `RTSNodeInvoker` directly, so nothing here reaches the JSON.
public struct RTSNodeStatus: Sendable {
    public enum State: Sendable {
        /// Created, but its body has not started — input guardrails and edge publication run in this
        /// window. Usually momentary, but a model-based guardrail (e.g. `RTSAppleAIPIIRedact*`) calls
        /// out to FoundationModels here, so it can last long enough to be worth showing.
        case queued
        /// The agent's LLM round-trip or the tool's body is running.
        case executing
        case completed
        case failed(String)
        /// Stopped from outside the node: the run was cancelled or timed out. Its body was cut short
        /// or never started. A node that fails on its own, including the one that triggers
        /// `endOnError`, is `.failed`.
        case cancelled
    }
    public let nodeID: UUID
    /// The invocation that triggered this one; `nil` at the flow root.
    ///
    /// Per-invocation, like `nodeID` — a node invoked N times is N distinct ids, so this forms a call
    /// tree rather than a graph of node instances. Consumers can also use `nil` to detect a new run:
    /// every run builds a fresh invoker, so only its root has no parent.
    public let parentNodeID: UUID?
    public let nodeName: String
    public let nodeType: RTSFlowNodeType
    public let state: State
    public let runID: RTSRunID?

    /// Public so consumers can construct statuses for SwiftUI previews and tests without driving a
    /// real flow. The library itself only ever builds these in `RTSFlow.startCollecting()`.
    public init(
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        state: State,
        runID: RTSRunID?
    ) {
        self.nodeID = nodeID
        self.parentNodeID = parentNodeID
        self.nodeName = nodeName
        self.nodeType = nodeType
        self.state = state
        self.runID = runID
    }
}
