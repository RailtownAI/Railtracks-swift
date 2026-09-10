//
//  ObservabilityLLMEmissionTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-09-08.
//

import Combine
import Foundation
import Testing
@testable import RailtracksSwift

private func str(_ value: RTSValue?) -> String? {
    if case let .string(text)? = value {
        return text
    }
    return nil
}

private struct StubLLMError: Error {
}

/// Lets a stub session hand its `run` closure's runID to its `message` closure, the way a
/// real session's `RunIDMap` does.
private final class RunIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    func set(_ runID: UUID?) {
        lock.lock()
        defer {
            lock.unlock()
        }
        value = runID
    }

    func get() -> UUID? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }
}

/// Collects a flow-free emitter's output.
private final class LLMEventRecorder: @unchecked Sendable {
    let emitter: RTSEventEmitter
    private let lock = NSLock()
    private var storage: [RTSEvent] = []
    private var cancellable: AnyCancellable?

    init() {
        emitter = RTSEventEmitter(sessionID: "session-1", isEnabled: true)
        cancellable = emitter.eventPublisher.sink { [weak self] event in
            guard let self else {
                return
            }
            self.lock.lock()
            self.storage.append(event)
            self.lock.unlock()
        }
    }

    var events: [RTSEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage
    }

    var eventTypes: [String] {
        events.map { $0.eventType }
    }

    func events(ofType eventType: String) -> [RTSEvent] {
        events.filter { $0.eventType == eventType }
    }

    func first(ofType eventType: String) -> RTSEvent? {
        events.first { $0.eventType == eventType }
    }
}

extension RailtracksSwiftTestSuite {

    /// Phase 2b: `llm.*`, the one family reconstructed from messages rather than observed.
    @Suite("Observability llm emission")
    struct ObservabilityLLMEmissionTests {

        private static let stamp = Date(timeIntervalSince1970: 1_788_000_000)
        private static let provider = RTSLLMProvider.openAI(modelIDString: "gpt-4o")

        private func message(
            _ role: RTSMessage.Role,
            _ text: String,
            latency: TimeInterval? = nil,
            at offset: TimeInterval = 0,
            runID: UUID? = nil
        ) -> RTSMessage {
            RTSMessage(
                id: UUID(),
                role: role,
                content: .text(text),
                timestamp: Self.stamp.addingTimeInterval(offset),
                metadata: RTSMessageMetadata(
                    tokenCount: 3,
                    inputTokenCount: 12,
                    generationTime: latency,
                    model: "gpt-4o-2024",
                    providerName: "OpenAI",
                    tokensPerSecond: nil,
                    providerExtra: ["system_fingerprint": "fp_1"],
                    custom: nil,
                    toolCalls: nil
                ),
                runID: runID
            )
        }

        private func emit(
            _ messages: [RTSMessage],
            nodeID: UUID = UUID(),
            error: Error? = nil,
            into recorder: LLMEventRecorder
        ) async {
            await RTSLLMEventEmission.emit(
                into: recorder.emitter,
                messages: messages,
                llmID: RTSLLMEventEmission.modelIdentifier(for: Self.provider),
                modelProvider: Self.provider.providerName,
                modelName: Self.provider.modelID,
                nodeID: nodeID,
                error: error
            )
        }

        // MARK: - Shape

        @Test("One creation/invocation/response triple per round trip")
        func triplePerRoundTrip() async {
            let recorder = LLMEventRecorder()
            // The tool-calling shape: two assistant messages, so two round trips.
            await emit(
                [
                    message(.user, "hi"),
                    message(.assistant, "calling a tool"),
                    message(.tool, "tool result"),
                    message(.assistant, "final answer"),
                ],
                into: recorder
            )

            #expect(
                recorder.eventTypes == [
                    "llm.creation", "llm.invocation", "llm.response",
                    "llm.creation", "llm.invocation", "llm.response",
                ]
            )
        }

        @Test("A message log with no assistant message emits nothing")
        func noAssistantMessagesEmitsNothing() async {
            let recorder = LLMEventRecorder()
            await emit([message(.user, "hi")], into: recorder)
            #expect(recorder.events.isEmpty)
        }

        @Test("llm.response carries what the provider reported")
        func responseCarriesProviderData() async throws {
            let recorder = LLMEventRecorder()
            await emit(
                [message(.user, "hi"), message(.assistant, "hello", latency: 1.5)],
                into: recorder
            )

            let response = try #require(recorder.first(ofType: "llm.response"))
            #expect(response.payload["reported_model_name"] == .string("gpt-4o-2024"))
            #expect(response.payload["input_tokens"] == .number(12))
            #expect(response.payload["output_tokens"] == .number(3))
            #expect(response.payload["system_fingerprint"] == .string("fp_1"))
            #expect(response.payload["latency"] == .number(1.5))
            // Input is every message before the assistant one.
            #expect(response.payload["message_input"] == .array([
                .object(["role": .string("user"), "content": .string("hi")]),
            ]))
        }

        // MARK: - Join keys
        //
        // Python's visualizer joins on these. Getting one wrong breaks the `llm_nodes` CTE
        // and the llm-traces joins *silently*, which is why they are asserted directly.

        @Test("llm_id is stable per model, llm_invoke_id distinct per round trip")
        func joinKeysAcrossRoundTrips() async throws {
            let recorder = LLMEventRecorder()
            await emit(
                [
                    message(.assistant, "first"),
                    message(.assistant, "second"),
                ],
                into: recorder
            )

            // `llm.creation.llm_id` is what `llm.*.parent_llm_type_id` joins to.
            let creationIDs = recorder.events(ofType: "llm.creation")
                .compactMap { str($0.payload["llm_id"]) }
            #expect(creationIDs.count == 2)
            #expect(Set(creationIDs).count == 1, "llm_id identifies the model, not the trip")

            let responses = recorder.events(ofType: "llm.response")
            let typeIDs = responses.compactMap { str($0.payload["parent_llm_type_id"]) }
            #expect(Set(typeIDs) == Set(creationIDs))

            let invokeIDs = responses.compactMap { str($0.payload["parent_llm_invoke_id"]) }
            #expect(invokeIDs.count == 2)
            #expect(Set(invokeIDs).count == 2, "llm_invoke_id identifies one round trip")
        }

        @Test("A round trip's invocation and response share one llm_invoke_id")
        func pairSharesInvokeID() async throws {
            let recorder = LLMEventRecorder()
            await emit([message(.assistant, "hello")], into: recorder)

            let invocation = try #require(recorder.first(ofType: "llm.invocation"))
            let response = try #require(recorder.first(ofType: "llm.response"))
            #expect(
                invocation.payload["parent_llm_invoke_id"]
                    == response.payload["parent_llm_invoke_id"]
            )
        }

        @Test("Every event names the enclosing node as its spatial parent")
        func spatialParentIsTheNode() async {
            let nodeID = UUID()
            let recorder = LLMEventRecorder()
            await emit([message(.assistant, "hello")], nodeID: nodeID, into: recorder)

            // The key Python's visualizer uses to attribute an LLM call to a node.
            for event in recorder.events(ofType: "llm.invocation")
                + recorder.events(ofType: "llm.response") {
                #expect(event.payload["spatial_parent_node_id"] == .string(nodeID.uuidString))
            }
        }

        @Test("llm.creation carries no parent, matching Python's CreationEventBase")
        func creationHasNoParent() async throws {
            let recorder = LLMEventRecorder()
            await emit([message(.assistant, "hello")], into: recorder)

            let creation = try #require(recorder.first(ofType: "llm.creation"))
            #expect(creation.payload["spatial_parent_type"] == .string("none"))
            #expect(!creation.payload.keys.contains("parent_type"))
        }

        // MARK: - Timestamps

        @Test("The request time is wound back from the response by its latency")
        func requestTimeDerivedFromLatency() async throws {
            let recorder = LLMEventRecorder()
            await emit([message(.assistant, "hello", latency: 2)], into: recorder)

            // Nothing observes the request moment — it happens inside Conduit — so it is
            // derived. The response time is real, carried through from the message.
            let invocation = try #require(recorder.first(ofType: "llm.invocation"))
            let response = try #require(recorder.first(ofType: "llm.response"))
            let requestedAt = try #require(
                RTSEventTimestamp.date(from: str(invocation.payload["timestamp"]) ?? "")
            )
            let respondedAt = try #require(
                RTSEventTimestamp.date(from: str(response.payload["timestamp"]) ?? "")
            )
            #expect(abs(respondedAt.timeIntervalSince(requestedAt) - 2) < 0.000_001)
        }

        // MARK: - Failure

        @Test("A failed invocation adds one llm.failure after the recovered round trips")
        func failureAfterPartialExchange() async throws {
            let recorder = LLMEventRecorder()
            // A partial exchange: one round trip completed, then the send threw.
            await emit(
                [message(.user, "hi"), message(.assistant, "partial")],
                error: StubLLMError(),
                into: recorder
            )

            #expect(
                recorder.eventTypes == [
                    "llm.creation", "llm.invocation", "llm.response", "llm.failure",
                ]
            )
            let failure = try #require(recorder.first(ofType: "llm.failure"))
            #expect(failure.payload["exception_name"] == .string("StubLLMError"))
            // Everything accumulated when the error surfaced — the trip that actually threw
            // left no assistant message, so it cannot be singled out.
            #expect(failure.payload["message_input"] != .null)
        }

        @Test("An error with no messages is not reported as an LLM failure")
        func errorWithoutMessagesIsNotAnLLMFailure() async throws {
            let recorder = LLMEventRecorder()
            // An empty log means the session was never used, so the fault was not the
            // model's. An agent throws before `session.run` for its own reasons — a missing
            // prompt key, say — and calling that an `llm.failure` would misattribute a
            // node-level fault to the provider and corrupt any error rate built from this
            // stream. Python's `LLMFailureEvent` comes only from inside the model call.
            await emit([], error: StubLLMError(), into: recorder)

            #expect(recorder.events.isEmpty)
        }

        @Test("An error is reported once the session has been used")
        func errorWithMessagesIsAnLLMFailure() async throws {
            let recorder = LLMEventRecorder()
            // Conduit appends the user message before contacting the provider, so a genuine
            // model failure always leaves at least this much behind — which is what separates
            // it from the case above.
            await emit([message(.user, "hi")], error: StubLLMError(), into: recorder)

            #expect(recorder.eventTypes == ["llm.failure"])
        }

        // MARK: - Cost when disabled

        @Test("A disabled emitter publishes nothing, from messages that otherwise would")
        func disabledEmitterIsSilent() async {
            let disabled = RTSEventEmitter(sessionID: "session-1", isEnabled: false)
            let recorder = LLMEventRecorder()

            await RTSLLMEventEmission.emit(
                into: disabled,
                messages: [message(.user, "hi"), message(.assistant, "hello", latency: 1)],
                llmID: "llm-1",
                modelProvider: "OpenAI",
                modelName: "gpt-4o",
                nodeID: UUID(),
                error: nil
            )

            #expect(recorder.events.isEmpty)
        }

        // NOTE: `emit` also guards on `isEnabled` *before* reconstructing, so a disabled flow
        // skips the cost lookups too — the reason the guard is there rather than left to
        // `emit`. That property is **not asserted here**: the work it avoids is an `await` on
        // `RTSCostCalculator.shared`, a singleton actor with no injection seam, so there is
        // nothing to observe. A test asserting "no events published" passes either way, which
        // is exactly how this shipped once with the work still running.

        // MARK: - Through the invoker

        @Test("An agent invocation emits llm.* inside its own node lifecycle")
        func emittedThroughInvokeAgent() async throws {
            let recorder = LLMEventRecorder()
            let base = [
                message(.user, "hi"),
                message(.assistant, "hello", latency: 1),
            ]
            // A real session stamps the messages a `run` produced with that call's runID, and
            // the invoker filters on it. The stub does the same, capturing the runID handed to
            // `run` — otherwise everything is filtered out, as the next test shows.
            let runIDBox = RunIDBox()
            let session = RTSLLMSession(
                run: { _, _, runID in
                    runIDBox.set(runID)
                    return "hello"
                },
                setSystemPrompt: { _, _ in },
                message: {
                    base.map { message in
                        RTSMessage(
                            id: message.id,
                            role: message.role,
                            content: message.content,
                            timestamp: message.timestamp,
                            metadata: message.metadata,
                            runID: runIDBox.get()
                        )
                    }
                },
                messageSubject: BufferedPassthroughSubject<[RTSMessage]>(),
                agentName: "Stub"
            )
            let invoker = RTSNodeInvoker(
                stampFactory: RTSStampFactory(),
                sessionID: UUID(),
                eventEmitter: recorder.emitter
            )
            let agent = RTSAgent(llmProvider: Self.provider, name: "Agent")

            _ = try await invoker.invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: session
            )

            // Placed after the body and before the terminal node event, so the LLM work sits
            // inside the node's own lifecycle — as it does in Python.
            #expect(
                recorder.eventTypes == [
                    "node.creation",
                    "node.invocation",
                    "llm.creation",
                    "llm.invocation",
                    "llm.response",
                    "node.response",
                    "node.destruction",
                ]
            )
        }

        @Test("Only this invocation's messages are reconstructed")
        func messagesAreScopedToTheInvocation() async throws {
            let recorder = LLMEventRecorder()
            // A session that has already served another invocation. Without the runID filter
            // the stale assistant message would produce a phantom round trip.
            let stale = message(.assistant, "from an earlier run", runID: UUID())
            let session = RTSLLMSession(
                run: { _, _, _ in "hello" },
                setSystemPrompt: { _, _ in },
                message: { [stale] },
                messageSubject: BufferedPassthroughSubject<[RTSMessage]>(),
                agentName: "Stub"
            )
            let invoker = RTSNodeInvoker(
                stampFactory: RTSStampFactory(),
                sessionID: UUID(),
                eventEmitter: recorder.emitter
            )
            let agent = RTSAgent(llmProvider: Self.provider, name: "Agent")

            _ = try await invoker.invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: session
            )

            #expect(recorder.events(ofType: "llm.response").isEmpty)
        }
    }
}
