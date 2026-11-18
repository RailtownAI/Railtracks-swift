//
//  RTSNodeFold.swift
//  RailtracksSwift
//

import Foundation

/// What the flow-graph trace and the Instruments signposts both know about a node between its
/// `node.creation` and `node.destruction`, built from the node's events.
///
/// `RTSFlowGraphCollector` and `RTSSignpostWriter` each keep a table of these, next to their own
/// fields, so the trace and Instruments read a node's parent, run id, input and messages the same
/// way. A value type with no side effects: each caller routes an event to its node with
/// ``nodeID(of:)``, applies it, and does its own recording around that.
struct RTSNodeFold: Sendable {
    let creation: RTSNodeCreationEvent
    /// The calling invocation's id, or `nil` at the flow root. Set at `node.invocation`.
    private(set) var parentNodeID: String?
    /// Set at `node.invocation`. Also the id of the edge into the node, as Python names an edge
    /// after its call's request id; the root's is the trace's `run_id`.
    private(set) var runID: RTSRunID?
    /// `node.invocation`'s `kwargs`, then each input guard transform in turn: the input the node's
    /// body received.
    private(set) var input: RTSInput = [:]
    /// The call's messages, from its latest `llm.response` or `llm.failure`.
    private(set) var messages: [RTSMessage] = []

    init(creation: RTSNodeCreationEvent) {
        self.creation = creation
    }

    /// The node `event` belongs to, or `nil` when it names none: a node event's own node, the node
    /// a guardrail ran on, or the agent that made an LLM call.
    static func nodeID(of event: any RTSObservabilityEvent) -> String? {
        switch event {
        case let creation as RTSNodeCreationEvent:
            return creation.nodeID
        case let invocation as RTSNodeInvocationEvent:
            return ownNodeID(invocation.parent)
        case let destruction as RTSNodeDestructionEvent:
            return ownNodeID(destruction.parent)
        case let response as RTSGuardInputResponseEvent:
            return guardedNodeID(response.spatialParent)
        case let failure as RTSGuardInputFailureEvent:
            return guardedNodeID(failure.spatialParent)
        case let response as RTSGuardOutputResponseEvent:
            return guardedNodeID(response.spatialParent)
        case let failure as RTSGuardOutputFailureEvent:
            return guardedNodeID(failure.spatialParent)
        case let response as RTSLLMResponseEvent:
            return callingNodeID(response.spatialParent)
        case let failure as RTSLLMFailureEvent:
            return callingNodeID(failure.spatialParent)
        default:
            return nil
        }
    }

    /// Folds `event` in. Events the fold doesn't read are ignored, and so is a `node.invocation`
    /// with no run id or no node as its spatial parent.
    mutating func apply(_ event: any RTSObservabilityEvent) {
        switch event {
        case let invocation as RTSNodeInvocationEvent:
            guard case .node(let parentNodeID) = invocation.spatialParent,
                  let runID = invocation.runID else {
                return
            }
            self.parentNodeID = parentNodeID
            self.runID = runID
            input = invocation.kwargs
        case let response as RTSGuardInputResponseEvent:
            if let transformed = response.decision.transformedDictionary {
                input = transformed
            }
        case let response as RTSLLMResponseEvent:
            // Each response's input is every message before its output, so the latest one holds
            // the whole call so far.
            messages = response.messageInput + (response.output.map { [$0] } ?? [])
        case let failure as RTSLLMFailureEvent:
            // A failure's input is everything the call had accumulated when it threw.
            messages = failure.messageInput
        default:
            break
        }
    }

    /// The node's output: a successful `node.destruction`'s response, when it is an object.
    static func output(of destruction: RTSNodeDestructionEvent) -> RTSOutput? {
        guard destruction.failure == nil, case .object(let response)? = destruction.response else {
            return nil
        }
        return response
    }

    private static func ownNodeID(_ parent: RTSEventParent) -> String? {
        guard case .node(let nodeID) = parent else {
            return nil
        }
        return nodeID
    }

    private static func guardedNodeID(_ spatialParent: RTSEventSpatialParent) -> String? {
        guard case .nodeAndMiddleware(let nodeID, _) = spatialParent else {
            return nil
        }
        return nodeID
    }

    private static func callingNodeID(_ spatialParent: RTSEventSpatialParent) -> String? {
        guard case .node(let nodeID?) = spatialParent else {
            return nil
        }
        return nodeID
    }
}
