//
//  RTSNodeEvents.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSNodeCreationEvent

/// A node was instantiated.
///
/// Mirrors the Python engine's `NodeCreation` (`events/node.py`). Emitted before the node
/// enters its own scope, so it resolves its parent from the caller's ambient chain and
/// carries no ``RTSEventParent`` — the Swift equivalent of Python's `CreationEventBase`.
public struct RTSNodeCreationEvent: RTSObservabilityEvent {
    public var eventType: String {
        "node.creation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let nodeID: String
    public let name: String
    public let nodeType: RTSFlowNodeType

    public init(
        nodeID: String,
        name: String,
        nodeType: RTSFlowNodeType,
        spatialParent: RTSEventSpatialParent = .noParent,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.nodeID = nodeID
        self.name = name
        self.nodeType = nodeType
        self.spatialParent = spatialParent
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = basePayload()
        payload["node_id"] = .string(nodeID)
        payload["name"] = .string(name)
        // `rawValue` deliberately, bypassing `RTSFlowNodeType`'s custom `Codable`, which maps
        // `.function` to `"Tool"` for the visualizer's benefit. The event stream wants the true
        // type: Python's `node_internals` fold keys off `node_type == "Agent"`.
        payload["node_type"] = .string(nodeType.rawValue)
        return payload
    }
}

// MARK: - RTSNodeInvocationEvent

/// Entering the node body.
///
/// Mirrors the Python engine's `NodeInvocation` (`events/node.py`).
public struct RTSNodeInvocationEvent: RTSParentedEvent {
    public var eventType: String {
        "node.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    /// Positional arguments. Always empty in Swift — nodes take keyed input only, the same
    /// reason the flow graph's `input_args` is always `[]`.
    public let args: [RTSValue]
    public let kwargs: RTSInput

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        args: [RTSValue] = [],
        kwargs: RTSInput,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.args = args
        self.kwargs = kwargs
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["args"] = .array(args)
        payload["kwargs"] = .object(kwargs)
        return payload
    }
}

// MARK: - RTSNodeResponseEvent

/// The node's own response.
///
/// Mirrors the Python engine's `NodeResponse` (`events/node.py`), which fires *inside* the
/// node's middleware. Swift has no middleware layer, so this and
/// ``RTSNodeDestructionEvent`` fire from the same point; both are kept so the event stream
/// stays shape-compatible with Python's.
public struct RTSNodeResponseEvent: RTSParentedEvent {
    public var eventType: String {
        "node.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        return payload
    }
}

// MARK: - RTSNodeFailureEvent

/// The node body threw.
///
/// Mirrors the Python engine's `NodeFailure` (`events/node.py`). Python composes this from
/// `FailureMixin`; Swift has no stored-property mixins, so the two fields are declared here
/// and ``from(error:parent:spatialParent:timestamp:)`` stands in for `from_exception`.
public struct RTSNodeFailureEvent: RTSParentedEvent {
    public var eventType: String {
        "node.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    /// Builds the event from a thrown error, mirroring Python's `FailureMixin.from_exception`.
    ///
    /// The message uses string interpolation deliberately: `RTSError`'s
    /// `CustomStringConvertible` omits call-site context so error strings stay byte-stable
    /// across the trace, and `RTSNodeInvoker` already stringifies errors the same way.
    public static func from(
        error: Error,
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        timestamp: Date = RTSEventTimestamp.now()
    ) -> RTSNodeFailureEvent {
        RTSNodeFailureEvent(
            parent: parent,
            spatialParent: spatialParent,
            exceptionName: String(describing: type(of: error)),
            exceptionMessage: "\(error)",
            timestamp: timestamp
        )
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["exception_name"] = .string(exceptionName)
        payload["exception_message"] = .string(exceptionMessage)
        return payload
    }
}

// MARK: - RTSNodeDestructionEvent

/// The node's final response, and how long it took.
///
/// Mirrors the Python engine's `NodeDestruction` (`events/node.py`), which fires *outside*
/// the node's middleware. This is the event carrying `duration_seconds`, and the one
/// Python's `node_internals` fold reads for latency.
public struct RTSNodeDestructionEvent: RTSParentedEvent {
    public var eventType: String {
        "node.destruction"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?
    /// Measured with a monotonic clock at the invocation site — never reconstructed from
    /// stamp deltas, which mispair when a node is invoked more than once.
    public let durationSeconds: TimeInterval

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        durationSeconds: TimeInterval,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.durationSeconds = durationSeconds
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        payload["duration_seconds"] = .number(durationSeconds)
        return payload
    }
}
