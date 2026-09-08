//
//  ObservabilityGuardrailEmissionTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-09-04.
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

private struct StubGuardrailError: Error {
}

/// Drives `RTSGuardrailRunner` directly, the way `GuardrailTests` already does — no flow or
/// LLM needed to exercise the `middleware.guard.*` emission path.
private final class GuardrailEventRecorder: @unchecked Sendable {
    let emitter: RTSEventEmitter
    private let lock = NSLock()
    private var storage: [RTSEvent] = []
    private var cancellable: AnyCancellable?

    init(isEnabled: Bool = true) {
        emitter = RTSEventEmitter(sessionID: "session-1", isEnabled: isEnabled)
        cancellable = emitter.eventPublisher.sink { [weak self] event in
            guard let self else {
                return
            }
            self.lock.lock()
            self.storage.append(event)
            self.lock.unlock()
        }
    }

    func context(nodeID: UUID = UUID(), agentName: String = "Agent") -> RTSGuardrailEventContext {
        RTSGuardrailEventContext(emitter: emitter, nodeID: nodeID, agentName: agentName)
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

    func first(ofType eventType: String) -> RTSEvent? {
        events.first { $0.eventType == eventType }
    }
}

extension RailtracksSwiftTestSuite {

    /// `middleware.guard.*` emission. Swift's guardrails are node-band by design — Conduit
    /// owns the tool-calling loop, so a node-level guard is the only interception point the
    /// library has — which is why these events carry a `node_and_middleware` spatial parent
    /// rather than Python's `llm_and_middleware`.
    @Suite("Observability guardrail emission")
    struct ObservabilityGuardrailEmissionTests {

        // MARK: - Happy path

        @Test("Each input rail emits creation, invocation and response")
        func inputRailSequence() async {
            let recorder = GuardrailEventRecorder()
            let allow = RTSClosureInputGuardrail(name: "allow") { _ in
                .allow("fine")
            }

            _ = await RTSGuardrailRunner.runInput(
                [allow],
                input: ["prompt": .string("hi")],
                eventContext: recorder.context()
            )

            // The chain-level pair brackets the guard-specific one, as Python's chain wraps
            // every middleware it runs.
            #expect(
                recorder.eventTypes == [
                    "middleware.creation",
                    "middleware.invocation",
                    "middleware.guard.input.invocation",
                    "middleware.guard.input.response",
                    "middleware.response",
                ]
            )
        }

        @Test("Each output rail emits its own three events")
        func outputRailSequence() async {
            let recorder = GuardrailEventRecorder()
            let allow = RTSClosureOutputGuardrail(name: "allow") { _ in
                .allow("fine")
            }

            _ = await RTSGuardrailRunner.runOutput(
                [allow],
                output: ["result": .string("ok")],
                eventContext: recorder.context()
            )

            #expect(
                recorder.eventTypes == [
                    "middleware.creation",
                    "middleware.invocation",
                    "middleware.guard.output.invocation",
                    "middleware.guard.output.response",
                    "middleware.response",
                ]
            )
        }

        @Test("Guard events name the node as their spatial parent, on the node band")
        func spatialParentIsTheNode() async throws {
            let nodeID = UUID()
            let recorder = GuardrailEventRecorder()
            let allow = RTSClosureInputGuardrail(name: "allow") { _ in
                .allow()
            }

            _ = await RTSGuardrailRunner.runInput(
                [allow],
                input: [:],
                eventContext: recorder.context(nodeID: nodeID)
            )

            let invocationType = "middleware.guard.input.invocation"
            let invocation = try #require(recorder.first(ofType: invocationType))
            #expect(invocation.payload["spatial_parent_type"] == .string("node_and_middleware"))
            #expect(invocation.payload["spatial_parent_node_id"] == .string(nodeID.uuidString))
            // Swift has no nested middleware, so there is never an intervening one.
            #expect(invocation.payload["spatial_parent_middleware_invoke_id"] == .null)
            #expect(invocation.payload["parent_type"] == .string("middleware"))
        }

        // MARK: - Chaining

        @Test("A rail's invocation carries the value the previous rail transformed")
        func invocationCarriesTransformedValue() async throws {
            let recorder = GuardrailEventRecorder()
            let upper = RTSClosureInputGuardrail(name: "upper") { input in
                guard let prompt = str(input["prompt"]) else {
                    return .allow()
                }
                return .transform(["prompt": .string(prompt.uppercased())], reason: "uppercased")
            }
            let observe = RTSClosureInputGuardrail(name: "observe") { _ in
                .allow("looks fine")
            }

            _ = await RTSGuardrailRunner.runInput(
                [upper, observe],
                input: ["prompt": .string("hello")],
                eventContext: recorder.context()
            )

            let invocations = recorder.events.filter {
                $0.eventType == "middleware.guard.input.invocation"
            }
            #expect(invocations.count == 2)
            let firstSaw = invocations[0].payload["message_history"]
            #expect(firstSaw == .object(["prompt": .string("hello")]))
            // The second rail sees the first rail's output, and its event records that.
            let secondSaw = invocations[1].payload["message_history"]
            #expect(secondSaw == .object(["prompt": .string("HELLO")]))
        }

        @Test("Two rails of the same type get distinct middleware type ids")
        func distinctTypeIDsForSameTypeRails() async throws {
            let recorder = GuardrailEventRecorder()
            // `name` defaults to the type name, so position is what keeps these apart.
            let first = RTSClosureInputGuardrail(name: "same") { _ in
                .allow()
            }
            let second = RTSClosureInputGuardrail(name: "same") { _ in
                .allow()
            }

            _ = await RTSGuardrailRunner.runInput(
                [first, second],
                input: [:],
                eventContext: recorder.context()
            )

            let creations = recorder.events.filter { $0.eventType == "middleware.creation" }
            #expect(creations.count == 2)
            let typeIDs = creations.compactMap { str($0.payload["middleware_type_id"]) }
            #expect(Set(typeIDs).count == 2)
        }

        @Test("middleware.creation fires once per rail across repeated runs")
        func creationIsAnnouncedOnce() async {
            let recorder = GuardrailEventRecorder()
            let allow = RTSClosureInputGuardrail(name: "allow") { _ in
                .allow()
            }
            let context = recorder.context()

            _ = await RTSGuardrailRunner.runInput([allow], input: [:], eventContext: context)
            _ = await RTSGuardrailRunner.runInput([allow], input: [:], eventContext: context)

            let creations = recorder.events.filter { $0.eventType == "middleware.creation" }
            #expect(creations.count == 1)
            // The invocation/response pairs still fire on both runs — one guard-level and one
            // chain-level per run.
            let guardInvocations = recorder.events.filter {
                $0.eventType == "middleware.guard.input.invocation"
            }
            #expect(guardInvocations.count == 2)
            #expect(
                recorder.events.filter { $0.eventType == "middleware.invocation" }.count == 2
            )
        }

        // MARK: - Block and failure

        @Test("A block is a guard-level decision and a chain-level failure")
        func blockIsAResponse() async throws {
            let recorder = GuardrailEventRecorder()
            let block = RTSClosureInputGuardrail(name: "block") { _ in
                .block("nope")
            }

            let outcome = await RTSGuardrailRunner.runInput(
                [block],
                input: [:],
                eventContext: recorder.context()
            )

            // The run still fails...
            #expect(outcome.error != nil)
            // ...and the two levels report it differently, exactly as Python does: the guard
            // records a verdict (`_raise_if_blocked` runs *after* its response event), while
            // the chain sees the resulting throw and records a failure.
            #expect(
                recorder.eventTypes == [
                    "middleware.creation",
                    "middleware.invocation",
                    "middleware.guard.input.invocation",
                    "middleware.guard.input.response",
                    "middleware.failure",
                ]
            )
            // Not a *guard* failure — those cover only the rail's `check` throwing.
            #expect(!recorder.eventTypes.contains("middleware.guard.input.failure"))
            let chainFailure = try #require(recorder.first(ofType: "middleware.failure"))
            #expect(chainFailure.payload["exception_name"] == .string("RTSError"))

            let response = try #require(recorder.first(ofType: "middleware.guard.input.response"))
            guard case .object(let decision)? = response.payload["decision"] else {
                Issue.record("decision should encode as an object")
                return
            }
            #expect(decision["action"] == .string("block"))
            #expect(decision["reason"] == .string("nope"))
        }

        @Test("A throwing rail emits a failure and no response")
        func throwingRailEmitsFailure() async throws {
            let recorder = GuardrailEventRecorder()
            let boom = RTSClosureInputGuardrail(name: "boom") { _ in
                throw StubGuardrailError()
            }

            _ = await RTSGuardrailRunner.runInput(
                [boom],
                input: [:],
                eventContext: recorder.context()
            )

            #expect(
                recorder.eventTypes == [
                    "middleware.creation",
                    "middleware.invocation",
                    "middleware.guard.input.invocation",
                    "middleware.guard.input.failure",
                    "middleware.failure",
                ]
            )
            let failure = try #require(recorder.first(ofType: "middleware.guard.input.failure"))
            #expect(failure.payload["exception_name"] == .string("StubGuardrailError"))
            // A throw is a failure at both levels, as in Python.
            let chainFailure = try #require(recorder.first(ofType: "middleware.failure"))
            #expect(chainFailure.payload["exception_name"] == .string("StubGuardrailError"))
        }

        @Test("A rail after a block never runs, and emits nothing")
        func blockShortCircuitsLaterRails() async {
            let recorder = GuardrailEventRecorder()
            let block = RTSClosureInputGuardrail(name: "block") { _ in
                .block("nope")
            }
            let never = RTSClosureInputGuardrail(name: "never") { _ in
                Issue.record("a rail after a block should not run")
                return .allow()
            }

            _ = await RTSGuardrailRunner.runInput(
                [block, never],
                input: [:],
                eventContext: recorder.context()
            )

            #expect(recorder.events.filter { $0.eventType == "middleware.creation" }.count == 1)
        }

        // MARK: - Node lifecycle around guardrails

        // These drive `RTSNodeInvoker.invokeAgent` directly with a stub session, because a
        // guardrail only reaches the invoker through an agent, and a real `RTSFlow` run would
        // need a working gateway. What they cover is the node events *around* the guardrails,
        // which the guard events themselves cannot show.

        /// An `RTSLLMSession` that answers without touching a provider.
        private func stubSession(_ reply: String = "ok") -> RTSLLMSession {
            RTSLLMSession(
                run: { _, _, _ in reply },
                setSystemPrompt: { _, _ in },
                message: { [] },
                messageSubject: BufferedPassthroughSubject<[RTSMessage]>(),
                agentName: "Stub"
            )
        }

        private func invoker(_ emitter: RTSEventEmitter) -> RTSNodeInvoker {
            RTSNodeInvoker(
                stampFactory: RTSStampFactory(),
                sessionID: UUID(),
                eventEmitter: emitter
            )
        }

        @Test("A blocked input guardrail still leaves the node a complete lifecycle")
        func blockedInputStillCompletesNodeLifecycle() async {
            let recorder = GuardrailEventRecorder()
            let block = RTSClosureInputGuardrail(name: "block") { _ in
                .block("nope")
            }
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: "gpt-4o"),
                name: "Guarded",
                inputGuardrails: [block]
            )

            _ = try? await invoker(recorder.emitter).invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: stubSession()
            )

            // `node.invocation` is emitted before the guardrails, so a block cannot leave the
            // node with a creation and a destruction and nothing in between. `node.failure` is
            // emitted even though the body never ran and nothing passed through the invoker's
            // `catch` — matching Python, where a blocked guard raises through the node body.
            let nodeEvents = recorder.eventTypes.filter { $0.hasPrefix("node.") }
            #expect(
                nodeEvents == [
                    "node.creation",
                    "node.invocation",
                    "node.failure",
                    "node.destruction",
                ]
            )
        }

        @Test("A blocked output guardrail yields a failure and no response")
        func blockedOutputYieldsFailureNotResponse() async {
            let recorder = GuardrailEventRecorder()
            let block = RTSClosureOutputGuardrail(name: "block") { _ in
                .block("unsafe")
            }
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: "gpt-4o"),
                name: "Guarded",
                outputGuardrails: [block]
            )

            _ = try? await invoker(recorder.emitter).invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: stubSession()
            )

            // The body *succeeded* here — only the output guardrail failed. Emitting
            // `node.response` next to `execute` would report both a response and a failure for
            // one invocation; the terminal event is singular instead.
            let nodeEvents = recorder.eventTypes.filter { $0.hasPrefix("node.") }
            #expect(
                nodeEvents == [
                    "node.creation",
                    "node.invocation",
                    "node.failure",
                    "node.destruction",
                ]
            )
            #expect(!nodeEvents.contains("node.response"))
        }

        @Test("A transforming output guardrail's result is what node.response carries")
        func nodeResponseCarriesGuardedOutput() async throws {
            let recorder = GuardrailEventRecorder()
            let redact = RTSClosureOutputGuardrail(name: "redact") { _ in
                .transform(["result": .string("[redacted]")], reason: "sensitive")
            }
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: "gpt-4o"),
                name: "Guarded",
                outputGuardrails: [redact]
            )

            _ = try? await invoker(recorder.emitter).invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: stubSession("my secret")
            )

            // The point of emitting at the terminal site: a redacting rail's result reaches the
            // stream, not the raw body output.
            let response = try #require(recorder.first(ofType: "node.response"))
            #expect(response.payload["response"] == .object(["result": .string("[redacted]")]))
        }

        // MARK: - Opt-out and default

        @Test("No event context means no events, and the runner behaves as before")
        func noContextEmitsNothing() async {
            let recorder = GuardrailEventRecorder()
            let upper = RTSClosureInputGuardrail(name: "upper") { input in
                guard let prompt = str(input["prompt"]) else {
                    return .allow()
                }
                return .transform(["prompt": .string(prompt.uppercased())], reason: "uppercased")
            }

            let outcome = await RTSGuardrailRunner.runInput(
                [upper],
                input: ["prompt": .string("hello")]
            )

            #expect(recorder.events.isEmpty)
            #expect(outcome.error == nil)
            #expect(str(outcome.value["prompt"]) == "HELLO")
            #expect(outcome.traces.count == 1)
        }

        @Test("The context's failable init yields no context when there is no emitter")
        func failableInitMirrorsEmitterAbsence() {
            // What lets `invokeAgent` pass its optional emitter straight through in an
            // expression position. A present emitter resolves to the non-optional overload
            // and is never nil; an absent one yields no context, and so no events.
            let present: RTSEventEmitter? = RTSEventEmitter(sessionID: "s", isEnabled: true)
            let absent: RTSEventEmitter? = nil

            #expect(
                RTSGuardrailEventContext(
                    emitter: present,
                    nodeID: UUID(),
                    agentName: "Agent"
                ) != nil
            )
            #expect(
                RTSGuardrailEventContext(
                    emitter: absent,
                    nodeID: UUID(),
                    agentName: "Agent"
                ) == nil
            )
        }

        @Test("A disabled emitter publishes nothing")
        func disabledEmitterIsSilent() async {
            let recorder = GuardrailEventRecorder(isEnabled: false)
            let allow = RTSClosureInputGuardrail(name: "allow") { _ in
                .allow()
            }

            _ = await RTSGuardrailRunner.runInput(
                [allow],
                input: [:],
                eventContext: recorder.context()
            )

            #expect(recorder.events.isEmpty)
        }
    }
}
