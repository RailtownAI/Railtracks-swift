//
//  RTSSessionEvents.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSSessionStatus

/// How a session ended.
///
/// Mirrors the Python engine's `SessionStatus` literal (`events/session.py`).
public enum RTSSessionStatus: String, Sendable, Codable {
    case success
    case failure
}

// MARK: - RTSSessionStartedEvent

/// A top-level run has begun.
///
/// Mirrors the Python engine's `SessionStarted` (`events/session.py`). Session events are
/// the root of the event tree: they are emitted outside any node scope, so there is nothing
/// above them to resolve — no ``RTSEventParent``, and a ``RTSEventSpatialParent`` of
/// ``RTSEventSpatialParent/noParent``.
///
/// `sessionID` appears both here and as the enclosing ``RTSEvent``'s `scopeID`, matching
/// Python.
public struct RTSSessionStartedEvent: RTSObservabilityEvent {
    /// The wire name, owned here alongside the type it names, so a consumer matching on it
    /// (``RTSEventWriter`` keys its per-run file handling off these) shares one definition
    /// rather than repeating the literal.
    public static let eventTypeName = "session.started"

    public var eventType: String {
        RTSSessionStartedEvent.eventTypeName
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let sessionID: String
    public let flowName: String?
    /// Hash of `flowName`. Produced by `RailtracksSwift.equalityHash(_:)`, the same hash the
    /// flow graph's `flow_id` uses.
    public let flowID: String?
    public let sessionName: String?
    public let entryPointName: String
    public let timeout: TimeInterval?
    public let endOnError: Bool
    public let saveState: Bool

    public init(
        sessionID: String,
        flowName: String?,
        flowID: String?,
        sessionName: String?,
        entryPointName: String,
        timeout: TimeInterval?,
        endOnError: Bool,
        saveState: Bool,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.sessionID = sessionID
        self.flowName = flowName
        self.flowID = flowID
        self.sessionName = sessionName
        self.entryPointName = entryPointName
        self.timeout = timeout
        self.endOnError = endOnError
        self.saveState = saveState
        self.spatialParent = .noParent
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = basePayload()
        payload["session_id"] = .string(sessionID)
        payload["flow_name"] = .nullable(flowName)
        payload["flow_id"] = .nullable(flowID)
        payload["session_name"] = .nullable(sessionName)
        payload["entry_point_name"] = .string(entryPointName)
        payload["timeout"] = .nullable(timeout)
        payload["end_on_error"] = .bool(endOnError)
        payload["save_state"] = .bool(saveState)
        return payload
    }
}

// MARK: - RTSSessionCompletedEvent

/// A top-level run has finished, successfully or otherwise.
///
/// Mirrors the Python engine's `SessionCompleted` (`events/session.py`). `error` is a
/// stringified exception and is set only when `status` is ``RTSSessionStatus/failure``.
public struct RTSSessionCompletedEvent: RTSObservabilityEvent {
    /// The wire name — see ``RTSSessionStartedEvent/eventTypeName``. This one is the event
    /// stream's end-of-run marker, so more than one consumer keys off it.
    public static let eventTypeName = "session.completed"

    public var eventType: String {
        RTSSessionCompletedEvent.eventTypeName
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let sessionID: String
    public let status: RTSSessionStatus
    public let error: String?
    public let durationSeconds: TimeInterval

    public init(
        sessionID: String,
        status: RTSSessionStatus,
        error: String?,
        durationSeconds: TimeInterval,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.sessionID = sessionID
        self.status = status
        self.error = error
        self.durationSeconds = durationSeconds
        self.spatialParent = .noParent
        self.timestamp = timestamp
    }

    /// Stringifies an error for an event payload, stripping ANSI colour escapes.
    ///
    /// Mirrors Python's `format_error` (`events/session.py`). String interpolation is used
    /// deliberately: `RTSError`'s `CustomStringConvertible` omits call-site context so error
    /// strings stay byte-stable across the trace.
    static func formatError(_ error: Error) -> String {
        let text = "\(error)"
        guard let pattern = ansiEscapePattern else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static let ansiEscapePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
    }()

    public func encodePayload() -> [String: RTSValue] {
        var payload = basePayload()
        payload["session_id"] = .string(sessionID)
        payload["status"] = .string(status.rawValue)
        payload["error"] = .nullable(error)
        payload["duration_seconds"] = .number(durationSeconds)
        return payload
    }
}
