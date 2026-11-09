//
//  RTSNodeStatusMapper.swift
//  RailtracksSwift
//

import Foundation
import Synchronization

/// Turns the emitter's internal stream into `RTSFlow.nodeStatusPublisher`'s statuses.
///
/// One per flow, subscribed in `RTSFlow.init`, so it sees every run's events from the first and
/// needs no run-scope filter: node ids are per invocation, so overlapping runs never collide.
///
/// - `node.creation` records the node's name and type.
/// - `node.invocation` adds its parent and run ID, and is `.queued`.
/// - The executing signal is `.executing`.
/// - `node.destruction` is `.completed`, `.failed` or `.cancelled`, and forgets the node.
///
/// See docs/node-status-from-events.md.
final class RTSNodeStatusMapper: Sendable {
    /// What the statuses need about a node, between its `node.creation` and `node.destruction`.
    private struct Node {
        let name: String
        let nodeType: RTSFlowNodeType
        var parentNodeID: UUID?
        var runID: RTSRunID?
    }

    /// Locked although the emitter delivers from one serial queue: that is the caller's guarantee,
    /// not this type's.
    private let nodes = Mutex<[RTSInvocationID: Node]>([:])

    /// The status `event` produces, or `nil` for an event that changes no node's state.
    func status(for event: RTSInternalEvent) -> RTSNodeStatus? {
        switch event {
        case .nodeExecuting(let signal):
            return status(of: signal.nodeID, state: .executing)
        case .observability(let event):
            switch event {
            case let creation as RTSNodeCreationEvent:
                recordCreation(creation)
                return nil
            case let invocation as RTSNodeInvocationEvent:
                return recordInvocation(invocation)
            case let destruction as RTSNodeDestructionEvent:
                return recordDestruction(destruction)
            default:
                return nil
            }
        }
    }

    /// The state a node's `node.destruction` reports. A node a stop cut short, whether by a cancel,
    /// a timeout or another node failing under `endOnError`, is `.cancelled`; a node that failed
    /// with its own error, including the one that triggered an end-on-error stop, is `.failed`.
    static func finishedState(of destruction: RTSNodeDestructionEvent) -> RTSNodeStatus.State {
        if destruction.terminationReason != nil {
            return .cancelled
        }
        guard let failure = destruction.failure else {
            return .completed
        }
        return .failed(failure.exceptionMessage)
    }

    private func recordCreation(_ creation: RTSNodeCreationEvent) {
        guard let nodeID = UUID(uuidString: creation.nodeID) else {
            log.warning("⚠️ node.creation with an unreadable node id: \(creation.nodeID)")
            return
        }
        nodes.withLock { nodes in
            nodes[nodeID] = Node(name: creation.name, nodeType: creation.nodeType)
        }
    }

    private func recordInvocation(_ invocation: RTSNodeInvocationEvent) -> RTSNodeStatus? {
        guard let nodeID = Self.nodeID(of: invocation.parent) else {
            return nil
        }
        var parentNodeID: UUID?
        if case .node(let parentIDText?) = invocation.spatialParent {
            parentNodeID = UUID(uuidString: parentIDText)
        }
        let found = nodes.withLock { nodes in
            nodes[nodeID]?.parentNodeID = parentNodeID
            nodes[nodeID]?.runID = invocation.runID
            return nodes[nodeID] != nil
        }
        guard found else {
            log.warning("⚠️ node.invocation with no node.creation before it")
            return nil
        }
        return status(of: nodeID, state: .queued)
    }

    private func recordDestruction(_ destruction: RTSNodeDestructionEvent) -> RTSNodeStatus? {
        guard let nodeID = Self.nodeID(of: destruction.parent),
              let node = nodes.withLock({ $0.removeValue(forKey: nodeID) }) else {
            log.warning("⚠️ node.destruction for a node never seen created")
            return nil
        }
        return Self.status(of: nodeID, node: node, state: Self.finishedState(of: destruction))
    }

    private func status(of nodeID: RTSInvocationID, state: RTSNodeStatus.State) -> RTSNodeStatus? {
        guard let node = nodes.withLock({ $0[nodeID] }) else {
            log.warning("⚠️ node status for a node never seen created")
            return nil
        }
        return Self.status(of: nodeID, node: node, state: state)
    }

    private static func status(
        of nodeID: RTSInvocationID,
        node: Node,
        state: RTSNodeStatus.State
    ) -> RTSNodeStatus {
        RTSNodeStatus(
            nodeID: nodeID,
            parentNodeID: node.parentNodeID,
            nodeName: node.name,
            nodeType: node.nodeType,
            state: state,
            runID: node.runID
        )
    }

    private static func nodeID(of parent: RTSEventParent) -> RTSInvocationID? {
        guard case .node(let nodeIDText) = parent else {
            return nil
        }
        return UUID(uuidString: nodeIDText)
    }
}
