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
