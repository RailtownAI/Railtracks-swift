//
//  ObservabilityEventTests.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation
import Testing
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {

    /// Phase 1 of the observability event port: the model only. These assert the wire shape
    /// against the Python engine's `Event.encode()` and `events/registry.py` column tables —
    /// nothing here exercises an emit site, because Phase 1 adds none.
    @Suite("Observability events")
    struct ObservabilityEventTests {

        // MARK: - Helpers

        /// Encodes to JSON and decodes back as a plain dictionary, so tests assert on the
        /// bytes that actually go on the wire rather than on Swift-side values.
        private func encodedJSON(_ event: RTSEvent) throws -> [String: Any] {
            let data = try JSONEncoder().encode(event)
            let object = try JSONSerialization.jsonObject(with: data)
            return try #require(object as? [String: Any])
        }

        private func makeEvent(
            eventType: String = "node.creation",
            parentScopeID: String? = nil,
            payload: [String: RTSValue] = [:]
        ) -> RTSEvent {
            RTSEvent(
                eventType: eventType,
                scopeType: .session,
                scopeID: "session-1",
                eventID: "event-1",
                stamp: Date(timeIntervalSince1970: 1_788_000_000.123456),
                parentScopeID: parentScopeID,
                payload: payload
            )
        }

        // MARK: - Envelope

        @Test("Envelope encodes exactly Python's seven snake_case keys")
        func envelopeKeys() throws {
            let json = try encodedJSON(makeEvent())
            #expect(
                Set(json.keys) == [
                    "event_type",
                    "scope_type",
                    "scope_id",
                    "event_id",
                    "stamp",
                    "parent_scope_id",
                    "payload",
                ]
            )
            #expect(json["event_type"] as? String == "node.creation")
            #expect(json["scope_type"] as? String == "session")
            #expect(json["scope_id"] as? String == "session-1")
            #expect(json["event_id"] as? String == "event-1")
        }

        @Test("parent_scope_id is written as null, not omitted")
        func parentScopeIDIsNull() throws {
            let json = try encodedJSON(makeEvent())
            #expect(json.keys.contains("parent_scope_id"))
            #expect(json["parent_scope_id"] is NSNull)
        }

        @Test("parent_scope_id carries its value when set")
        func parentScopeIDIsCarried() throws {
            let json = try encodedJSON(makeEvent(parentScopeID: "outer"))
            #expect(json["parent_scope_id"] as? String == "outer")
        }

        @Test("Payload values encode as bare JSON, not tagged enums")
        func payloadIsBareJSON() throws {
            let payload: [String: RTSValue] = [
                "text": .string("hello"),
                "count": .number(3),
                "flag": .bool(true),
                "missing": .null,
            ]
            let json = try encodedJSON(makeEvent(payload: payload))
            let encoded = try #require(json["payload"] as? [String: Any])
            #expect(encoded["text"] as? String == "hello")
            #expect(encoded["count"] as? Double == 3)
            #expect(encoded["flag"] as? Bool == true)
            #expect(encoded["missing"] is NSNull)
        }

        // MARK: - Timestamps

        @Test("stamp matches Python's datetime.isoformat() spelling")
        func stampFormat() throws {
            let json = try encodedJSON(makeEvent())
            let stamp = try #require(json["stamp"] as? String)
            let isoPattern = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00/
            #expect(stamp.wholeMatch(of: isoPattern) != nil)
            #expect(stamp == "2026-08-29T10:40:00.123456+00:00")
        }

        @Test("Timestamps round trip through the wire format")
        func timestampRoundTrip() throws {
            let original = Date(timeIntervalSince1970: 1_788_000_000.123456)
            let text = RTSEventTimestamp.isoString(from: original)
            let parsed = try #require(RTSEventTimestamp.date(from: text))
            #expect(abs(parsed.timeIntervalSince1970 - original.timeIntervalSince1970) < 0.000_001)
        }

        @Test("A whole-second instant still writes six fractional digits")
        func timestampWholeSecond() {
            let instant = Date(timeIntervalSince1970: 1_788_000_000)
            let stamp = RTSEventTimestamp.isoString(from: instant)
            #expect(stamp == "2026-08-29T10:40:00.000000+00:00")
        }

        @Test("A stamp that rounds up to the next second stays consistent")
        func timestampRoundsUp() {
            let instant = Date(timeIntervalSince1970: 1_788_000_000.9999999)
            let stamp = RTSEventTimestamp.isoString(from: instant)
            #expect(stamp == "2026-08-29T10:40:01.000000+00:00")
        }

        @Test("A Z-suffixed stamp parses to the same instant")
        func timestampParsesZuluForm() throws {
            let parsed = try #require(RTSEventTimestamp.date(from: "2026-08-29T10:40:00.123456Z"))
            #expect(abs(parsed.timeIntervalSince1970 - 1_788_000_000.123456) < 0.000_001)
        }

        @Test("Envelope round trips through Codable")
        func envelopeRoundTrip() throws {
            let original = makeEvent(parentScopeID: "outer", payload: ["node_id": .string("n1")])
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(RTSEvent.self, from: data)
            #expect(decoded.eventType == original.eventType)
            #expect(decoded.scopeType == original.scopeType)
            #expect(decoded.scopeID == original.scopeID)
            #expect(decoded.eventID == original.eventID)
            #expect(decoded.parentScopeID == original.parentScopeID)
            let decodedSeconds = decoded.stamp.timeIntervalSince1970
            let originalSeconds = original.stamp.timeIntervalSince1970
            #expect(abs(decodedSeconds - originalSeconds) < 0.000_001)
        }

        @Test("A malformed stamp fails to decode rather than defaulting")
        func envelopeRejectsBadStamp() throws {
            let json = """
            {"event_type":"node.creation","scope_type":"session","scope_id":"s","event_id":"e",
             "stamp":"not-a-date","parent_scope_id":null,"payload":{}}
            """
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(RTSEvent.self, from: Data(json.utf8))
            }
        }

        // MARK: - Parentage flattening

        @Test("Spatial parent cases flatten to exactly Python's asdict() keys")
        func spatialParentFlattening() {
            let cases: [(RTSEventSpatialParent, [String: RTSValue])] = [
                (.noParent, ["type": .string("none")]),
                (.middleware(middlewareInvokeID: "m1"),
                 ["type": .string("middleware"), "middleware_invoke_id": .string("m1")]),
                (.node(nodeID: "n1"),
                 ["type": .string("node"), "node_id": .string("n1")]),
                (.node(nodeID: nil),
                 ["type": .string("node"), "node_id": .null]),
                (.nodeAndMiddleware(nodeID: "n1", middlewareInvokeID: nil),
                 ["type": .string("node_and_middleware"),
                  "node_id": .string("n1"),
                  "middleware_invoke_id": .null]),
                (.llmAndMiddleware(llmInvokeID: "l1", middlewareInvokeID: "m1"),
                 ["type": .string("llm_and_middleware"),
                  "llm_invoke_id": .string("l1"),
                  "middleware_invoke_id": .string("m1")]),
            ]
            for (spatialParent, expected) in cases {
                let event = RTSNodeCreationEvent(
                    nodeID: "n",
                    name: "Node",
                    nodeType: .tool,
                    spatialParent: spatialParent
                )
                let payload = event.encodePayload()
                let flattened = expected.reduce(into: [String: RTSValue]()) { result, entry in
                    result["spatial_parent_\(entry.key)"] = entry.value
                }
                for (key, value) in flattened {
                    #expect(payload[key] == value, "\(spatialParent) key \(key)")
                }
                let spatialKeys = payload.keys.filter { $0.hasPrefix("spatial_parent_") }
                #expect(Set(spatialKeys) == Set(flattened.keys), "\(spatialParent) key set")
            }
        }

        @Test("Parent cases flatten to exactly Python's asdict() keys")
        func parentFlattening() {
            let cases: [(RTSEventParent, Set<String>)] = [
                (.node(nodeID: "n1"), ["parent_type", "parent_node_id"]),
                (.middleware(middlewareTypeID: "t", middlewareInvokeID: "i"),
                 ["parent_type", "parent_middleware_type_id", "parent_middleware_invoke_id"]),
                (.llm(llmTypeID: "t", llmInvokeID: "i"),
                 ["parent_type", "parent_llm_type_id", "parent_llm_invoke_id"]),
            ]
            for (parent, expectedKeys) in cases {
                let event = RTSNodeResponseEvent(
                    parent: parent,
                    spatialParent: .node(nodeID: nil),
                    response: nil
                )
                let payload = event.encodePayload()
                let parentKeys = payload.keys.filter { $0.hasPrefix("parent_") }
                #expect(Set(parentKeys) == expectedKeys, "\(parent)")
                #expect(payload["parent_type"] == .string(parent.type.rawValue))
            }
        }

        // MARK: - Node events

        @Test("node.creation carries the creation columns and no parent block")
        func nodeCreationPayload() {
            let event = RTSNodeCreationEvent(nodeID: "n1", name: "Adder", nodeType: .agent)
            #expect(event.eventType == "node.creation")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp", "spatial_parent_type", "node_id", "name", "node_type",
                ]
            )
            #expect(payload["node_id"] == .string("n1"))
            #expect(payload["name"] == .string("Adder"))
            #expect(payload["node_type"] == .string("Agent"))
        }

        @Test("node.creation reports the true node type, not the visualizer's spelling")
        func nodeCreationFunctionType() {
            // `RTSFlowNodeType.function` serializes as "Tool" in the flow-graph JSON; the event
            // stream reports "Function", matching Python's `node_type`.
            let event = RTSNodeCreationEvent(
                nodeID: "n1",
                name: "Orchestrator",
                nodeType: .function
            )
            #expect(event.encodePayload()["node_type"] == .string("Function"))
        }

        @Test("node.invocation carries args and kwargs")
        func nodeInvocationPayload() {
            let event = RTSNodeInvocationEvent(
                parent: .node(nodeID: "n1"),
                spatialParent: .node(nodeID: nil),
                kwargs: ["prompt": .string("hi")]
            )
            #expect(event.eventType == "node.invocation")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp", "spatial_parent_type", "spatial_parent_node_id",
                    "parent_type", "parent_node_id", "args", "kwargs",
                ]
            )
            #expect(payload["args"] == .array([]))
            #expect(payload["kwargs"] == .object(["prompt": .string("hi")]))
        }

        @Test("node.response writes null for an absent response")
        func nodeResponsePayload() {
            let event = RTSNodeResponseEvent(
                parent: .node(nodeID: "n1"),
                spatialParent: .noParent,
                response: nil
            )
            #expect(event.eventType == "node.response")
            #expect(event.encodePayload()["response"] == .null)
        }

        @Test("node.failure derives its fields from a thrown error")
        func nodeFailurePayload() {
            let error = RTSError.missingInput("prompt")
            let event = RTSNodeFailureEvent.from(
                error: error,
                parent: .node(nodeID: "n1"),
                spatialParent: .noParent
            )
            #expect(event.eventType == "node.failure")
            let payload = event.encodePayload()
            #expect(payload["exception_name"] == .string("RTSError"))
            // Matches how `RTSNodeInvoker` stringifies errors — no call-site context.
            #expect(payload["exception_message"] == .string("\(error)"))
        }

        @Test("node.destruction carries the response and duration")
        func nodeDestructionPayload() {
            let event = RTSNodeDestructionEvent(
                parent: .node(nodeID: "n1"),
                spatialParent: .node(nodeID: "caller"),
                response: .object(["sum": .number(3)]),
                durationSeconds: 1.5
            )
            #expect(event.eventType == "node.destruction")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp", "spatial_parent_type", "spatial_parent_node_id",
                    "parent_type", "parent_node_id", "response", "duration_seconds",
                ]
            )
            #expect(payload["duration_seconds"] == .number(1.5))
            #expect(payload["response"] == .object(["sum": .number(3)]))
        }

        // MARK: - Session events

        @Test("session.started carries the registry's session columns")
        func sessionStartedPayload() {
            let event = RTSSessionStartedEvent(
                sessionID: "s1",
                flowName: "Demo",
                flowID: "abc123",
                sessionName: nil,
                entryPointName: "Root",
                timeout: nil,
                endOnError: false,
                saveState: true
            )
            #expect(event.eventType == "session.started")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp", "spatial_parent_type", "session_id", "flow_name", "flow_id",
                    "session_name", "entry_point_name", "timeout", "end_on_error", "save_state",
                ]
            )
            #expect(payload["spatial_parent_type"] == .string("none"))
            #expect(payload["session_name"] == .null)
            #expect(payload["timeout"] == .null)
            #expect(payload["end_on_error"] == .bool(false))
            #expect(payload["save_state"] == .bool(true))
        }

        @Test("session.completed carries status, error and duration")
        func sessionCompletedPayload() {
            let event = RTSSessionCompletedEvent(
                sessionID: "s1",
                status: .success,
                error: nil,
                durationSeconds: 2.25
            )
            #expect(event.eventType == "session.completed")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp", "spatial_parent_type", "session_id",
                    "status", "error", "duration_seconds",
                    "fatal", "termination_reason",
                ]
            )
            #expect(payload["status"] == .string("success"))
            #expect(payload["error"] == .null)
            #expect(payload["duration_seconds"] == .number(2.25))
            #expect(payload["fatal"] == .bool(false))
            #expect(payload["termination_reason"] == .null)
        }

        @Test("session.completed carries fatal and the termination reason's wire value")
        func sessionCompletedTerminationPayload() {
            let event = RTSSessionCompletedEvent(
                sessionID: "s1",
                status: .failure,
                error: "runTerminated(reason: endOnError(…))",
                durationSeconds: 1,
                fatal: true,
                terminationReason: .endOnError
            )
            let payload = event.encodePayload()
            #expect(payload["fatal"] == .bool(true))
            #expect(payload["termination_reason"] == .string("end_on_error"))
        }

        /// A user cancel isn't fatal; the engine's own stops are, as Python's `fatal` means.
        @Test("termination reasons map from the run's reason, with fatal for engine stops only")
        func sessionTerminationReasonMapping() {
            let cancelled = RTSSessionTerminationReason(.cancelled)
            let timeout = RTSSessionTerminationReason(.timeout(after: 30))
            let endOnError = RTSSessionTerminationReason(
                .endOnError(nodeName: "Tool", underlying: URLError(.badServerResponse))
            )

            #expect(cancelled == .cancelled)
            #expect(timeout == .timeout)
            #expect(endOnError == .endOnError)
            #expect(!cancelled.isFatal)
            #expect(timeout.isFatal)
            #expect(endOnError.isFatal)
        }

        @Test("session.completed strips ANSI escapes from the error, like Python's format_error")
        func sessionCompletedStripsANSI() {
            let message = RTSSessionCompletedEvent.formatError(
                ObservabilityTestError(description: "\u{1B}[31mboom\u{1B}[0m")
            )
            #expect(message == "boom")
        }

        // MARK: - Envelope + typed event

        @Test("A typed event wraps into a session-scoped envelope")
        func sessionScoping() {
            let event = RTSNodeCreationEvent(nodeID: "n1", name: "Adder", nodeType: .tool)
            let envelope = RTSEvent.session(event, sessionID: "s1")
            #expect(envelope.eventType == "node.creation")
            #expect(envelope.scopeType == .session)
            #expect(envelope.scopeID == "s1")
            #expect(envelope.parentScopeID == nil)
            #expect(envelope.payload["node_id"] == .string("n1"))
        }

        // MARK: - Golden fixtures

        @Test("node.destruction matches the Python wire shape end to end")
        func goldenNodeDestruction() throws {
            let node = RTSNodeDestructionEvent(
                parent: .node(nodeID: "node-1"),
                spatialParent: .node(nodeID: nil),
                response: .object(["answer": .string("42")]),
                durationSeconds: 0.5,
                timestamp: Date(timeIntervalSince1970: 1_788_000_000.123456)
            )
            let envelope = RTSEvent(
                eventType: node.eventType,
                scopeType: .session,
                scopeID: "session-1",
                eventID: "event-1",
                stamp: Date(timeIntervalSince1970: 1_788_000_000.123456),
                payload: node.encodePayload()
            )
            let expected = """
            {
              "event_type": "node.destruction",
              "scope_type": "session",
              "scope_id": "session-1",
              "event_id": "event-1",
              "stamp": "2026-08-29T10:40:00.123456+00:00",
              "parent_scope_id": null,
              "payload": {
                "timestamp": "2026-08-29T10:40:00.123456+00:00",
                "spatial_parent_type": "node",
                "spatial_parent_node_id": null,
                "parent_type": "node",
                "parent_node_id": "node-1",
                "response": {"answer": "42"},
                "duration_seconds": 0.5
              }
            }
            """
            try expectJSONEqual(envelope, expected)
        }

        @Test("session.completed matches the Python wire shape end to end")
        func goldenSessionCompleted() throws {
            let session = RTSSessionCompletedEvent(
                sessionID: "session-1",
                status: .failure,
                error: "boom",
                durationSeconds: 3,
                timestamp: Date(timeIntervalSince1970: 1_788_000_000.123456)
            )
            let envelope = RTSEvent(
                eventType: session.eventType,
                scopeType: .session,
                scopeID: "session-1",
                eventID: "event-2",
                stamp: Date(timeIntervalSince1970: 1_788_000_000.123456),
                payload: session.encodePayload()
            )
            let expected = """
            {
              "event_type": "session.completed",
              "scope_type": "session",
              "scope_id": "session-1",
              "event_id": "event-2",
              "stamp": "2026-08-29T10:40:00.123456+00:00",
              "parent_scope_id": null,
              "payload": {
                "timestamp": "2026-08-29T10:40:00.123456+00:00",
                "spatial_parent_type": "none",
                "session_id": "session-1",
                "status": "failure",
                "error": "boom",
                "duration_seconds": 3,
                "fatal": false,
                "termination_reason": null
              }
            }
            """
            try expectJSONEqual(envelope, expected)
        }

        /// Compares the encoded event against a JSON literal, key order irrelevant.
        private func expectJSONEqual(
            _ event: RTSEvent,
            _ expected: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let actualData = try JSONEncoder().encode(event)
            let actual = try JSONSerialization.jsonObject(with: actualData)
            let expectedObject = try JSONSerialization.jsonObject(with: Data(expected.utf8))
            #expect(
                (actual as? NSDictionary) == (expectedObject as? NSDictionary),
                "\(String(decoding: actualData, as: UTF8.self))",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - ObservabilityTestError

/// An error whose description carries ANSI colour codes, for the `format_error` port.
private struct ObservabilityTestError: Error, CustomStringConvertible {
    let description: String
}
