//
//  RTSNodeIdentity.swift
//  RailtracksSwift
//

import Foundation

/// Where the code running on this task sits in a flow: its session, run and node, the same IDs the
/// flow's trace and events use.
///
/// Read it with ``current`` from inside a node, for example in a tool's closure or an
/// orchestrator's `run`, to tag a log line or a record of your own so it can be matched with the
/// trace. Read-only: only the node invoker sets it, around each node's body.
public struct RTSNodeIdentity: Sendable, Equatable {
    /// The flow's session: `RTSFlow.id`, the trace's `session_id`.
    public let sessionID: UUID
    /// The node invocation's run ID: `run_id` on `node.invocation`, and the ID of the edge into the
    /// node in the trace.
    public let runID: RTSRunID
    /// The node invocation's ID in the trace and the events. A new one each time a node is invoked.
    public let nodeID: UUID

    /// The node running on this task, or `nil` outside a node in a flow.
    ///
    /// Child tasks inherit it (a `TaskGroup`, `async let`, an unstructured `Task`), so code a node
    /// runs concurrently still reads the node's identity. A `Task.detached` doesn't: it starts with
    /// none. A node invoked without a flow has none either.
    public static var current: RTSNodeIdentity? {
        RTSNodeInvoker.currentNode
    }
}
