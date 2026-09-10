//
//  ObservabilityMiddlewareEventTests.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation
import Testing
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {

    /// The `middleware.*` family. Key sets are asserted against the `middleware` namespace
    /// in the Python engine's `events/registry.py`.
    ///
    /// Fourteen of these twenty-one types have no Swift emit site — Swift has no middleware
    /// layer — so a payload-shape assertion is the *only* thing keeping them correct. That
    /// makes the coverage here load-bearing rather than incidental.
    @Suite("Observability middleware events")
    struct ObservabilityMiddlewareEventTests {

        private static let stamp = Date(timeIntervalSince1970: 1_788_000_000.123456)
        private static let parent = RTSEventParent.middleware(
            middlewareTypeID: "rail-type-1",
            middlewareInvokeID: "rail-run-1"
        )
        private static let nodeBand = RTSEventSpatialParent.nodeAndMiddleware(
            nodeID: "node-1",
            middlewareInvokeID: nil
        )
        private static let modelBand = RTSEventSpatialParent.llmAndMiddleware(
            llmInvokeID: "call-1",
            middlewareInvokeID: nil
        )

        /// The flattened parent + spatial-parent keys every non-creation event carries.
        private static let nodeBandBaseKeys: Set<String> = [
            "timestamp",
            "spatial_parent_type", "spatial_parent_node_id", "spatial_parent_middleware_invoke_id",
            "parent_type", "parent_middleware_type_id", "parent_middleware_invoke_id",
        ]
        private static let modelBandBaseKeys: Set<String> = [
            "timestamp",
            "spatial_parent_type", "spatial_parent_llm_invoke_id",
            "spatial_parent_middleware_invoke_id",
            "parent_type", "parent_middleware_type_id", "parent_middleware_invoke_id",
        ]
        private static let failureKeys: Set<String> = ["exception_name", "exception_message"]

        private func decision(_ action: RTSGuardrailDecision.Action) -> RTSGuardrailDecision {
            RTSGuardrailDecision(action: action, reason: "because")
        }

        /// Asserts an event's payload carries exactly `expected` keys.
        private func expectKeys(
            _ event: some RTSObservabilityEvent,
            _ expected: Set<String>,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            #expect(Set(event.encodePayload().keys) == expected, sourceLocation: sourceLocation)
        }

        // MARK: - Creation

        @Test("middleware.creation carries the definition columns and no parent block")
        func creationPayload() {
            let event = RTSMiddlewareCreationEvent(
                middlewareTypeID: "rail-type-1",
                middlewareName: "LengthGuard"
            )
            #expect(event.eventType == "middleware.creation")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp", "spatial_parent_type", "middleware_type_id", "middleware_name",
                ]
            )
            #expect(payload["spatial_parent_type"] == .string("none"))
        }

        // MARK: - The seven Swift emits

        @Test("Guard events carry their registry columns, on the node band")
        func guardPayloads() {
            let input: RTSInput = ["prompt": .string("hi")]
            let output: RTSOutput = ["answer": .string("42")]

            let inputInvocation = RTSGuardInputInvocationEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                messageHistory: input
            )
            #expect(inputInvocation.eventType == "middleware.guard.input.invocation")
            expectKeys(inputInvocation, Self.nodeBandBaseKeys.union(["message_history"]))

            let inputResponse = RTSGuardInputResponseEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                messageHistory: input,
                decision: decision(.allow)
            )
            #expect(inputResponse.eventType == "middleware.guard.input.response")
            expectKeys(inputResponse, Self.nodeBandBaseKeys.union(["message_history", "decision"]))

            let outputInvocation = RTSGuardOutputInvocationEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                response: output
            )
            #expect(outputInvocation.eventType == "middleware.guard.output.invocation")
            expectKeys(outputInvocation, Self.nodeBandBaseKeys.union(["response"]))

            let outputResponse = RTSGuardOutputResponseEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                response: output,
                decision: decision(.transform)
            )
            #expect(outputResponse.eventType == "middleware.guard.output.response")
            expectKeys(outputResponse, Self.nodeBandBaseKeys.union(["response", "decision"]))
        }

        @Test("Guard failure events derive their fields from a thrown error")
        func guardFailures() {
            let error = RTSError.invalidInvocation("boom")

            let inputFailure = RTSGuardInputFailureEvent.from(
                error: error,
                parent: Self.parent,
                spatialParent: Self.nodeBand
            )
            #expect(inputFailure.eventType == "middleware.guard.input.failure")
            expectKeys(inputFailure, Self.nodeBandBaseKeys.union(Self.failureKeys))
            #expect(inputFailure.encodePayload()["exception_name"] == .string("RTSError"))

            let outputFailure = RTSGuardOutputFailureEvent.from(
                error: error,
                parent: Self.parent,
                spatialParent: Self.nodeBand
            )
            #expect(outputFailure.eventType == "middleware.guard.output.failure")
            #expect(outputFailure.encodePayload()["exception_message"] == .string("\(error)"))
        }

        @Test("A block is reported on the response event, not as a failure")
        func blockIsNotAFailure() {
            // Mirrors Python: `_raise_if_blocked` runs *after* the response event is emitted,
            // so a block surfaces as a decision, and the resulting error unwinds separately.
            let event = RTSGuardInputResponseEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                messageHistory: ["prompt": .string("hi")],
                decision: decision(.block)
            )
            let payload = event.encodePayload()
            #expect(event.eventType == "middleware.guard.input.response")
            guard case .object(let encoded)? = payload["decision"] else {
                Issue.record("decision should encode as an object")
                return
            }
            #expect(encoded["action"] == .string("block"))
        }

        // MARK: - The fourteen with no Swift emit site

        @Test("Bare middleware triple carries the chain's columns")
        func bareTriple() {
            let invocation = RTSMiddlewareInvocationEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                kwargs: ["a": .number(1)]
            )
            #expect(invocation.eventType == "middleware.invocation")
            expectKeys(invocation, Self.nodeBandBaseKeys.union(["args", "kwargs"]))
            #expect(invocation.encodePayload()["args"] == .array([]))

            let response = RTSMiddlewareResponseEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                response: .string("ok")
            )
            #expect(response.eventType == "middleware.response")
            expectKeys(response, Self.nodeBandBaseKeys.union(["response"]))

            let failure = RTSMiddlewareFailureEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                exceptionName: "E",
                exceptionMessage: "m"
            )
            #expect(failure.eventType == "middleware.failure")
            expectKeys(failure, Self.nodeBandBaseKeys.union(Self.failureKeys))
        }

        @Test("Model-band events carry message_history, tools and schema, on the llm band")
        func modelBandPayloads() {
            let keys = Self.modelBandBaseKeys.union(["message_history", "tools", "schema"])

            let invocation = RTSMiddlewareModelInvocationEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                messageHistory: [],
                tools: .array([.string("search")]),
                schema: nil
            )
            #expect(invocation.eventType == "middleware.model.invocation")
            expectKeys(invocation, keys)
            // `tools` lives here, not on any llm.* event — the point that makes the two
            // families easy to confuse.
            #expect(invocation.encodePayload()["tools"] == .array([.string("search")]))
            #expect(invocation.encodePayload()["schema"] == .null)

            let inputInvocation = RTSMiddlewareModelInputInvocationEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                messageHistory: [],
                tools: nil,
                schema: nil
            )
            #expect(inputInvocation.eventType == "middleware.model.input.invocation")
            expectKeys(inputInvocation, keys)

            let inputResponse = RTSMiddlewareModelInputResponseEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                messageHistory: [],
                tools: nil,
                schema: nil
            )
            #expect(inputResponse.eventType == "middleware.model.input.response")
            expectKeys(inputResponse, keys)
        }

        @Test("Response-shaped model and regular events carry only `response`")
        func responseShapedEvents() {
            let modelKeys = Self.modelBandBaseKeys.union(["response"])
            let nodeKeys = Self.nodeBandBaseKeys.union(["response"])

            let modelResponse = RTSMiddlewareModelResponseEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                response: .string("r")
            )
            #expect(modelResponse.eventType == "middleware.model.response")
            expectKeys(modelResponse, modelKeys)

            let outputInvocation = RTSMiddlewareModelOutputInvocationEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                response: .string("r")
            )
            #expect(outputInvocation.eventType == "middleware.model.output.invocation")
            expectKeys(outputInvocation, modelKeys)

            let outputResponse = RTSMiddlewareModelOutputResponseEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                response: .string("r")
            )
            #expect(outputResponse.eventType == "middleware.model.output.response")
            expectKeys(outputResponse, modelKeys)

            let regularInvocation = RTSMiddlewareRegularOutputInvocationEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                response: .string("r")
            )
            #expect(regularInvocation.eventType == "middleware.regular.output.invocation")
            expectKeys(regularInvocation, nodeKeys)

            let regularResponse = RTSMiddlewareRegularOutputResponseEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                response: .string("r")
            )
            #expect(regularResponse.eventType == "middleware.regular.output.response")
            expectKeys(regularResponse, nodeKeys)
        }

        @Test("Remaining failure events carry the failure pair")
        func remainingFailures() {
            let modelFailure = RTSMiddlewareModelFailureEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                exceptionName: "E",
                exceptionMessage: "m"
            )
            #expect(modelFailure.eventType == "middleware.model.failure")
            expectKeys(modelFailure, Self.modelBandBaseKeys.union(Self.failureKeys))

            let modelOutputFailure = RTSMiddlewareModelOutputFailureEvent(
                parent: Self.parent,
                spatialParent: Self.modelBand,
                exceptionName: "E",
                exceptionMessage: "m"
            )
            #expect(modelOutputFailure.eventType == "middleware.model.output.failure")

            let regularOutputFailure = RTSMiddlewareRegularOutputFailureEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                exceptionName: "E",
                exceptionMessage: "m"
            )
            #expect(regularOutputFailure.eventType == "middleware.regular.output.failure")
            expectKeys(regularOutputFailure, Self.nodeBandBaseKeys.union(Self.failureKeys))
        }

        @Test("All 21 event_type strings are present and distinct")
        func eventTypeCoverage() {
            // The Python namespace has exactly these. Anything missing here means a type was
            // dropped; anything duplicated means one was mis-copied.
            let expected: Set<String> = [
                "middleware.creation",
                "middleware.invocation", "middleware.response", "middleware.failure",
                "middleware.model.invocation", "middleware.model.response",
                "middleware.model.failure",
                "middleware.model.input.invocation", "middleware.model.input.response",
                "middleware.model.output.invocation", "middleware.model.output.response",
                "middleware.model.output.failure",
                "middleware.guard.input.invocation", "middleware.guard.input.response",
                "middleware.guard.input.failure",
                "middleware.guard.output.invocation", "middleware.guard.output.response",
                "middleware.guard.output.failure",
                "middleware.regular.output.invocation", "middleware.regular.output.response",
                "middleware.regular.output.failure",
            ]
            #expect(expected.count == 21)

            let actual: [String] = [
                RTSMiddlewareCreationEvent(middlewareTypeID: "t", middlewareName: "n").eventType,
                RTSMiddlewareInvocationEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    kwargs: [:]
                ).eventType,
                RTSMiddlewareResponseEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    response: nil
                ).eventType,
                RTSMiddlewareFailureEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    exceptionName: "",
                    exceptionMessage: ""
                ).eventType,
                RTSMiddlewareModelInvocationEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    messageHistory: [],
                    tools: nil,
                    schema: nil
                ).eventType,
                RTSMiddlewareModelResponseEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    response: nil
                ).eventType,
                RTSMiddlewareModelFailureEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    exceptionName: "",
                    exceptionMessage: ""
                ).eventType,
                RTSMiddlewareModelInputInvocationEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    messageHistory: [],
                    tools: nil,
                    schema: nil
                ).eventType,
                RTSMiddlewareModelInputResponseEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    messageHistory: [],
                    tools: nil,
                    schema: nil
                ).eventType,
                RTSMiddlewareModelOutputInvocationEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    response: nil
                ).eventType,
                RTSMiddlewareModelOutputResponseEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    response: nil
                ).eventType,
                RTSMiddlewareModelOutputFailureEvent(
                    parent: Self.parent,
                    spatialParent: Self.modelBand,
                    exceptionName: "",
                    exceptionMessage: ""
                ).eventType,
                RTSGuardInputInvocationEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    messageHistory: [:]
                ).eventType,
                RTSGuardInputResponseEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    messageHistory: [:],
                    decision: decision(.allow)
                ).eventType,
                RTSGuardInputFailureEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    exceptionName: "",
                    exceptionMessage: ""
                ).eventType,
                RTSGuardOutputInvocationEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    response: [:]
                ).eventType,
                RTSGuardOutputResponseEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    response: [:],
                    decision: decision(.allow)
                ).eventType,
                RTSGuardOutputFailureEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    exceptionName: "",
                    exceptionMessage: ""
                ).eventType,
                RTSMiddlewareRegularOutputInvocationEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    response: nil
                ).eventType,
                RTSMiddlewareRegularOutputResponseEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    response: nil
                ).eventType,
                RTSMiddlewareRegularOutputFailureEvent(
                    parent: Self.parent,
                    spatialParent: Self.nodeBand,
                    exceptionName: "",
                    exceptionMessage: ""
                ).eventType,
            ]
            #expect(actual.count == 21)
            #expect(Set(actual) == expected)
        }

        // MARK: - Decision container

        @Test("Decisions build from guardrail results and always write every key")
        func decisionEncoding() {
            let allowed = RTSGuardrailDecision(RTSInputGuardrailResult.allow("fine"))
            #expect(allowed.action == .allow)
            #expect(allowed.transformedValue == nil)

            let transformed = RTSGuardrailDecision(
                RTSInputGuardrailResult.transform(["prompt": .string("clean")], reason: "redacted")
            )
            #expect(transformed.action == .transform)
            #expect(transformed.transformedValue == .object(["prompt": .string("clean")]))

            let blocked = RTSGuardrailDecision(
                RTSOutputGuardrailResult.block("nope", metadata: ["rule": .string("pii")])
            )
            #expect(blocked.action == .block)

            guard case .object(let encoded) = allowed.encoded() else {
                Issue.record("decision should encode as an object")
                return
            }
            #expect(Set(encoded.keys) == ["action", "reason", "transformed_value", "meta"])
            #expect(encoded["transformed_value"] == .null)
            #expect(encoded["meta"] == .null)
        }

        // MARK: - Golden fixture

        @Test("middleware.guard.input.response matches the Python wire shape end to end")
        func goldenGuardResponse() throws {
            let guardEvent = RTSGuardInputResponseEvent(
                parent: Self.parent,
                spatialParent: Self.nodeBand,
                messageHistory: ["prompt": .string("hi")],
                decision: RTSGuardrailDecision(action: .allow, reason: "fine"),
                timestamp: Self.stamp
            )
            let envelope = RTSEvent(
                eventType: guardEvent.eventType,
                scopeType: .session,
                scopeID: "session-1",
                eventID: "event-1",
                stamp: Self.stamp,
                payload: guardEvent.encodePayload()
            )
            let expected = """
            {
              "event_type": "middleware.guard.input.response",
              "scope_type": "session",
              "scope_id": "session-1",
              "event_id": "event-1",
              "stamp": "2026-08-29T10:40:00.123456+00:00",
              "parent_scope_id": null,
              "payload": {
                "timestamp": "2026-08-29T10:40:00.123456+00:00",
                "spatial_parent_type": "node_and_middleware",
                "spatial_parent_node_id": "node-1",
                "spatial_parent_middleware_invoke_id": null,
                "parent_type": "middleware",
                "parent_middleware_type_id": "rail-type-1",
                "parent_middleware_invoke_id": "rail-run-1",
                "message_history": {"prompt": "hi"},
                "decision": {
                  "action": "allow",
                  "reason": "fine",
                  "transformed_value": null,
                  "meta": null
                }
              }
            }
            """
            let actualData = try JSONEncoder().encode(envelope)
            let actual = try JSONSerialization.jsonObject(with: actualData)
            let expectedObject = try JSONSerialization.jsonObject(with: Data(expected.utf8))
            #expect(
                (actual as? NSDictionary) == (expectedObject as? NSDictionary),
                "\(String(decoding: actualData, as: UTF8.self))"
            )
        }
    }
}
