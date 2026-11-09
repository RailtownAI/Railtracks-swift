//
//  RTSInternalEvent.swift
//  RailtracksSwift
//

import Foundation

// MARK: - RTSInternalEvent

/// One event on the emitter's internal stream, ``RTSEventEmitter/observedEventPublisher``.
///
/// An event with a Python wire form is an ``RTSObservabilityEvent``, and also goes on the public
/// stream. One with no wire form is its own case here: it doesn't conform to
/// ``RTSObservabilityEvent``, so it can never become an envelope, and only reaches the internal
/// stream. See docs/node-status-from-events.md.
enum RTSInternalEvent: Sendable {
    /// An event that also goes on the public stream, when the emitter is enabled.
    case observability(any RTSObservabilityEvent)
    /// A node's body is about to run. Internal stream only.
    case nodeExecuting(RTSNodeExecutingSignal)

    /// The event, when it is one that also goes on the public stream.
    var observabilityEvent: (any RTSObservabilityEvent)? {
        guard case .observability(let event) = self else {
            return nil
        }
        return event
    }
}

// MARK: - RTSNodeExecutingSignal

/// A node's guardrails are done and its body is about to run: the queued → executing point.
///
/// Python has no such event, so it has no wire form. Sent unconditionally, also when an input
/// guardrail already failed or the run was stopped before the node, so a node is never finished
/// without having been seen to start.
struct RTSNodeExecutingSignal: Sendable {
    /// The node's per-invocation id, as in its `node.creation`.
    let nodeID: RTSInvocationID
    let timestamp: Date

    init(nodeID: RTSInvocationID, timestamp: Date = RTSEventTimestamp.now()) {
        self.nodeID = nodeID
        self.timestamp = timestamp
    }
}
