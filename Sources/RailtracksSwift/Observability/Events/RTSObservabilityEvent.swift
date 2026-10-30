//
//  RTSObservabilityEvent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSObservabilityEvent

/// A typed observability event: the fields that become an ``RTSEvent``'s payload.
///
/// Mirrors the Python engine's `SessionEventBase` (`events/_base.py`). Python builds the
/// payload by walking the dataclass fields and expanding anything tagged `flatten` into
/// `<field>_<key>` pairs; ``basePayload()`` below does the same for the fields every event
/// carries, and each concrete event adds its own on top.
///
/// Types conforming to this protocol *only* — rather than to ``RTSParentedEvent`` — are the
/// Swift equivalent of Python's `CreationEventBase` and `SessionEventFamilyBase`: events
/// emitted before the entity enters its own scope, so they have no `parent`.
public protocol RTSObservabilityEvent: Sendable {
    /// Dotted event name, e.g. `"node.creation"`. Mirrors Python's `event_type()`.
    var eventType: String { get }
    /// When the event was created.
    var timestamp: Date { get }
    /// The scope this event was emitted from.
    var spatialParent: RTSEventSpatialParent { get }
    /// The flat, snake_case payload for this event.
    func encodePayload() -> [String: RTSValue]
}

extension RTSObservabilityEvent {
    /// `timestamp` plus the flattened `spatial_parent_*` block — the fields every event has.
    public func basePayload() -> [String: RTSValue] {
        var payload: [String: RTSValue] = [:]
        payload["timestamp"] = .string(RTSEventTimestamp.isoString(from: timestamp))
        for (key, value) in spatialParent.encodedFields() {
            payload["spatial_parent_\(key)"] = value
        }
        return payload
    }
}

// MARK: - RTSParentedEvent

/// An event emitted from inside the entity's own scope, so it names that entity as its
/// `parent` as well as naming the enclosing scope as its `spatialParent`.
///
/// Mirrors the Python engine's `ParentEventBase` (`events/_base.py`).
public protocol RTSParentedEvent: RTSObservabilityEvent {
    /// The entity this event is about.
    var parent: RTSEventParent { get }
}

extension RTSParentedEvent {
    /// ``basePayload()`` plus the flattened `parent_*` block.
    public func parentedBasePayload() -> [String: RTSValue] {
        var payload = basePayload()
        for (key, value) in parent.encodedFields() {
            payload["parent_\(key)"] = value
        }
        return payload
    }
}

// MARK: - RTSFailureReporting

/// The two fields every `*.failure` event carries.
///
/// Mirrors the Python engine's `FailureMixin` (`events/_base.py`). Python composes it in
/// as a dataclass mixin; Swift has no stored-property mixins, so conformers declare the
/// two fields themselves and pick up the payload contribution from the extension below.
public protocol RTSFailureReporting {
    var exceptionName: String { get }
    var exceptionMessage: String { get }
}

extension RTSFailureReporting {
    /// The `exception_name` / `exception_message` payload pair.
    public func failurePayloadFields() -> [String: RTSValue] {
        [
            "exception_name": .string(exceptionName),
            "exception_message": .string(exceptionMessage),
        ]
    }
}

// MARK: - RTSEventFailure

/// Derives failure fields from a thrown error.
///
/// Mirrors the Python engine's `FailureMixin.from_exception`.
public enum RTSEventFailure {
    /// The `(exception_name, exception_message)` pair for `error`.
    ///
    /// The message uses string interpolation deliberately: `RTSError`'s
    /// `CustomStringConvertible` omits call-site context so error strings stay byte-stable
    /// across the trace, and `RTSNodeInvoker` already stringifies errors the same way.
    public static func fields(from error: Error) -> (name: String, message: String) {
        (name: String(describing: type(of: error)), message: "\(error)")
    }

    /// Where an `RTSError` was thrown, as `thrown at <file>:<line> in <function>`, or `nil` for
    /// any other error, which carries no call site.
    ///
    /// Swift has no stack trace to offer, so this stands in for one: it is the `traceback` of
    /// the node events and of the trace's failed-edge `output`. The file is `#fileID`, so
    /// module-relative.
    public static func callSite(of error: Error) -> String? {
        guard let railtracksError = error as? RTSError else {
            return nil
        }
        let context = railtracksError.context
        return "thrown at \(context.file):\(context.line) in \(context.function)"
    }
}

// MARK: - RTSEventFrame

/// One frame of a failure's traceback.
///
/// Mirrors the Python engine's `Frame` (`events/node.py`). Swift records only an `RTSError`'s
/// call site, so a failure has at most one frame, and `source` is always empty.
public struct RTSEventFrame: Sendable, Equatable {
    public let file: String
    public let line: Int?
    public let function: String
    public let source: String

    public init(file: String, line: Int?, function: String, source: String) {
        self.file = file
        self.line = line
        self.function = function
        self.source = source
    }

    /// The `{file, line, function, source}` object.
    public func encoded() -> RTSValue {
        .object([
            "file": .string(file),
            "line": line.map { .number(Double($0)) } ?? .null,
            "function": .string(function),
            "source": .string(source),
        ])
    }
}

// MARK: - RTSEventFailureDetails

/// The failure fields `node.failure` and `node.destruction` carry for an error.
///
/// Mirrors the Python engine's `failure_details(exc)` (`events/node.py`). Both events take
/// their values from one of these, so a node's two events agree by construction.
public struct RTSEventFailureDetails: Sendable, Equatable {
    public let exceptionName: String
    public let exceptionMessage: String
    /// ``RTSEventFailure/callSite(of:)``, or `""` for an error with none: Python's default.
    public let traceback: String
    /// One frame for an `RTSError`'s call site, outermost first as in Python; otherwise empty.
    public let frames: [RTSEventFrame]
    /// Python's `is_fatal(exc)`: the error's own fatal flag, not the run's `endOnError`. Always
    /// `false`, since Swift has no fatal-error marker yet.
    public let fatal: Bool

    public init(_ error: Error) {
        let fields = RTSEventFailure.fields(from: error)
        self.exceptionName = fields.name
        self.exceptionMessage = fields.message
        self.traceback = RTSEventFailure.callSite(of: error) ?? ""
        if let railtracksError = error as? RTSError {
            let context = railtracksError.context
            self.frames = [
                RTSEventFrame(
                    file: context.file,
                    line: Int(context.line),
                    function: context.function,
                    source: ""
                )
            ]
        } else {
            self.frames = []
        }
        self.fatal = false
    }
}

// MARK: - RTSValue nullable helpers

extension RTSValue {
    /// `.null` for a missing value.
    ///
    /// Python's event encoding always writes the key, so an absent value has to become a
    /// JSON `null` rather than an omitted key.
    static func nullable(_ value: String?) -> RTSValue {
        guard let value else {
            return .null
        }
        return .string(value)
    }

    /// `.null` for a missing value. See ``nullable(_:)-(String?)``.
    static func nullable(_ value: Int?) -> RTSValue {
        guard let value else {
            return .null
        }
        return .number(Double(value))
    }

    /// `.null` for a missing value. See ``nullable(_:)-(String?)``.
    static func nullable(_ value: Double?) -> RTSValue {
        guard let value else {
            return .null
        }
        return .number(value)
    }

    /// `.null` for a missing value. See ``nullable(_:)-(String?)``.
    static func nullable(_ value: RTSValue?) -> RTSValue {
        value ?? .null
    }

    /// Lifts any `Encodable` into an `RTSValue` by round-tripping it through JSON.
    ///
    /// The event payload's harder-typed fields — `message_history`, `tools`, `schema`,
    /// `response`, `decision`, `args`, `kwargs` — are all `JSON` columns in the Python
    /// engine's `events/registry.py`, so this is the general lift for all of them.
    ///
    /// Returns `.null` if the value cannot be encoded, matching the Python writer's
    /// encoder, which degrades rather than failing the event.
    static func encoding(_ value: some Encodable) -> RTSValue {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(RTSValue.self, from: data)
        } catch {
            log.warning("⚠️ observability: could not encode payload value: \(error)")
            return .null
        }
    }
}
