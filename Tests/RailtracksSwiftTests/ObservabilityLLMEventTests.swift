//
//  ObservabilityLLMEventTests.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation
import Testing
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {

    /// The `llm.*` family. Key sets are asserted against the `llm` namespace in the Python
    /// engine's `events/registry.py`, which is the hand-maintained wire contract.
    @Suite("Observability llm events")
    struct ObservabilityLLMEventTests {

        private static let stamp = Date(timeIntervalSince1970: 1_788_000_000.123456)

        private func message(_ role: RTSMessage.Role, _ text: String) -> RTSMessage {
            RTSMessage(
                id: UUID(),
                role: role,
                content: .text(text),
                timestamp: Self.stamp,
                metadata: nil,
                runID: nil
            )
        }

        // MARK: - Provider mapping

        @Test("Swift provider names map to Python's ModelProvider values")
        func providerMapping() {
            // `model_provider` is an enum column in the Python registry, so a Swift-only
            // spelling would violate the consumer's schema. Two of the four diverge.
            #expect(RTSEventModelProvider.wireValue(for: "OpenAI") == "OpenAI")
            #expect(RTSEventModelProvider.wireValue(for: "Anthropic") == "Anthropic")
            // Python's `GEMINI` member, whose wire value is a misnomer: Conduit reaches
            // Gemini through Google AI Studio, not Vertex AI. It is the only Google member
            // the enum column accepts. See `RTSEventModelProvider`.
            #expect(RTSEventModelProvider.wireValue(for: "Gemini") == "Vertex_AI")
            #expect(RTSEventModelProvider.wireValue(for: "AppleAI") == "apple")
            #expect(RTSEventModelProvider.wireValue(for: "something else") == "Unknown")
        }

        @Test("Every RTSLLMProvider case maps to a known Python value")
        func everyProviderMaps() {
            // Guards against a new Swift provider silently landing as "Unknown".
            let pythonMembers: Set<String> = [
                "OpenAI", "Anthropic", "Vertex_AI", "HuggingFace",
                "AzureAI", "Ollama", "PortKey", "apple",
            ]
            for provider in RTSLLMProvider.allCases {
                let wire = RTSEventModelProvider.wireValue(for: provider.providerName)
                #expect(pythonMembers.contains(wire), "\(provider.providerName) -> \(wire)")
            }
        }

        // MARK: - Payload key sets

        @Test("llm.creation carries the creation columns and no parent block")
        func creationPayload() {
            let event = RTSLLMCreationEvent(
                llmID: "model-1",
                modelProvider: "Gemini",
                modelName: "gemini-2.0"
            )
            #expect(event.eventType == "llm.creation")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp", "spatial_parent_type", "llm_id", "model_provider", "model_name",
                ]
            )
            #expect(payload["spatial_parent_type"] == .string("none"))
            #expect(payload["model_provider"] == .string("Vertex_AI"))
        }

        @Test("llm.invocation carries the message history")
        func invocationPayload() {
            let event = RTSLLMInvocationEvent(
                parent: .llm(llmTypeID: "model-1", llmInvokeID: "call-1"),
                spatialParent: .node(nodeID: "node-1"),
                messageInput: [message(.user, "hi")]
            )
            #expect(event.eventType == "llm.invocation")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp",
                    "spatial_parent_type", "spatial_parent_node_id",
                    "parent_type", "parent_llm_type_id", "parent_llm_invoke_id",
                    "message_input",
                ]
            )
            #expect(payload["parent_type"] == .string("llm"))
            let userMessage = RTSValue.object(["role": .string("user"), "content": .string("hi")])
            #expect(payload["message_input"] == .array([userMessage]))
        }

        @Test("llm.response carries every provider-reported column")
        func responsePayload() {
            let event = RTSLLMResponseEvent(
                parent: .llm(llmTypeID: "model-1", llmInvokeID: "call-1"),
                spatialParent: .node(nodeID: "node-1"),
                messageInput: [message(.user, "hi")],
                output: message(.assistant, "hello"),
                reportedModelName: "gpt-5",
                inputTokens: 12,
                outputTokens: 3,
                totalCost: 0.25,
                systemFingerprint: "fp_1",
                latency: 1.5
            )
            #expect(event.eventType == "llm.response")
            let payload = event.encodePayload()
            #expect(
                Set(payload.keys) == [
                    "timestamp",
                    "spatial_parent_type", "spatial_parent_node_id",
                    "parent_type", "parent_llm_type_id", "parent_llm_invoke_id",
                    "message_input", "output", "reported_model_name",
                    "input_tokens", "output_tokens", "total_cost",
                    "system_fingerprint", "latency",
                ]
            )
            #expect(payload["input_tokens"] == .number(12))
            #expect(payload["total_cost"] == .number(0.25))
            let assistantMessage: RTSValue = .object([
                "role": .string("assistant"),
                "content": .string("hello"),
            ])
            #expect(payload["output"] == assistantMessage)
        }

        @Test("llm.response writes null for every absent optional")
        func responseNulls() {
            let event = RTSLLMResponseEvent(
                parent: .llm(llmTypeID: "model-1", llmInvokeID: "call-1"),
                spatialParent: .node(nodeID: nil),
                messageInput: [],
                output: nil
            )
            let payload = event.encodePayload()
            for key in ["output", "reported_model_name", "input_tokens",
                        "output_tokens", "total_cost", "system_fingerprint", "latency"] {
                #expect(payload[key] == .null, "\(key)")
            }
        }

        @Test("llm.failure derives its fields from a thrown error")
        func failurePayload() {
            let error = RTSError.missingInput("prompt")
            let event = RTSLLMFailureEvent.from(
                error: error,
                parent: .llm(llmTypeID: "model-1", llmInvokeID: "call-1"),
                spatialParent: .node(nodeID: "node-1"),
                messageInput: [message(.user, "hi")]
            )
            #expect(event.eventType == "llm.failure")
            let payload = event.encodePayload()
            #expect(payload["exception_name"] == .string("RTSError"))
            #expect(payload["exception_message"] == .string("\(error)"))
            #expect(payload.keys.contains("message_input"))
        }

        // MARK: - Non-text message content

        // Python's `Message.encode()` returns `{"role": role.value, "content": content}` with
        // `content` passed through raw, so it recurses into whatever the content object is:
        // `ToolCall`/`ToolResponse` are pydantic models dumped by field name, and `ToolCalls`
        // is a `list` subclass dumped as an array. These assert Swift produces the same
        // shapes through the event path, not just for plain strings.

        @Test("An assistant tool-call message encodes as Python's ToolCall array")
        func toolCallMessageShape() {
            let call = RTSToolCall(
                id: "call-1",
                toolName: "Photo_Search",
                arguments: RTSGeneratedContent(kind: .structure([
                    "query": RTSGeneratedContent(kind: .string("cats")),
                ]))
            )
            let assistant = RTSMessage(
                id: UUID(),
                role: .assistant,
                content: .text("I'll look that up."),
                timestamp: Self.stamp,
                metadata: RTSMessageMetadata(
                    tokenCount: nil,
                    inputTokenCount: nil,
                    generationTime: nil,
                    model: nil,
                    providerName: nil,
                    tokensPerSecond: nil,
                    providerExtra: nil,
                    custom: nil,
                    toolCalls: [call]
                ),
                runID: nil
            )
            let event = RTSLLMInvocationEvent(
                parent: .llm(llmTypeID: "model-1", llmInvokeID: "call-1"),
                spatialParent: .node(nodeID: "node-1"),
                messageInput: [assistant]
            )
            // Field names are ToolCall's pydantic fields: identifier / name / arguments.
            let expected: RTSValue = .array([
                .object([
                    "role": .string("assistant"),
                    "content": .array([
                        .object([
                            "identifier": .string("call-1"),
                            "name": .string("Photo_Search"),
                            "arguments": .object(["query": .string("cats")]),
                        ]),
                    ]),
                ]),
            ])
            #expect(event.encodePayload()["message_input"] == expected)
        }

        @Test("A tool-response message encodes as Python's ToolResponse object")
        func toolResponseMessageShape() {
            let toolMessage = RTSMessage(
                id: UUID(),
                role: .tool,
                content: .text("12 photos"),
                timestamp: Self.stamp,
                metadata: RTSMessageMetadata(
                    tokenCount: nil,
                    inputTokenCount: nil,
                    generationTime: nil,
                    model: nil,
                    providerName: nil,
                    tokensPerSecond: nil,
                    providerExtra: nil,
                    custom: ["tool_call_id": "call-1", "tool_name": "Photo_Search"],
                    toolCalls: nil
                ),
                runID: nil
            )
            let event = RTSLLMInvocationEvent(
                parent: .llm(llmTypeID: "model-1", llmInvokeID: "call-1"),
                spatialParent: .node(nodeID: "node-1"),
                messageInput: [toolMessage]
            )
            // Field names are ToolResponse's pydantic fields: identifier / name / result.
            let expected: RTSValue = .array([
                .object([
                    "role": .string("tool"),
                    "content": .object([
                        "identifier": .string("call-1"),
                        "name": .string("Photo_Search"),
                        "result": .string("12 photos"),
                    ]),
                ]),
            ])
            #expect(event.encodePayload()["message_input"] == expected)
        }

        // MARK: - Golden fixture

        @Test("llm.response matches the Python wire shape end to end")
        func goldenResponse() throws {
            let llm = RTSLLMResponseEvent(
                parent: .llm(llmTypeID: "model-1", llmInvokeID: "call-1"),
                spatialParent: .node(nodeID: "node-1"),
                messageInput: [message(.user, "hi")],
                output: message(.assistant, "hello"),
                reportedModelName: "gpt-5",
                inputTokens: 12,
                outputTokens: 3,
                totalCost: 0.25,
                systemFingerprint: "fp_1",
                latency: 1.5,
                timestamp: Self.stamp
            )
            let envelope = RTSEvent(
                eventType: llm.eventType,
                scopeType: .session,
                scopeID: "session-1",
                eventID: "event-1",
                stamp: Self.stamp,
                payload: llm.encodePayload()
            )
            let expected = """
            {
              "event_type": "llm.response",
              "scope_type": "session",
              "scope_id": "session-1",
              "event_id": "event-1",
              "stamp": "2026-08-29T10:40:00.123456+00:00",
              "parent_scope_id": null,
              "payload": {
                "timestamp": "2026-08-29T10:40:00.123456+00:00",
                "spatial_parent_type": "node",
                "spatial_parent_node_id": "node-1",
                "parent_type": "llm",
                "parent_llm_type_id": "model-1",
                "parent_llm_invoke_id": "call-1",
                "message_input": [{"role": "user", "content": "hi"}],
                "output": {"role": "assistant", "content": "hello"},
                "reported_model_name": "gpt-5",
                "input_tokens": 12,
                "output_tokens": 3,
                "total_cost": 0.25,
                "system_fingerprint": "fp_1",
                "latency": 1.5
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
