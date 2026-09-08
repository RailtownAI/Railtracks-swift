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

            #expect(
                recorder.eventTypes == [
                    "middleware.creation",
                    "middleware.guard.input.invocation",
                    "middleware.guard.input.response",
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
                    "middleware.guard.output.invocation",
                    "middleware.guard.output.response",
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
            // The invocation/response pair still fires on both runs.
            #expect(recorder.events.filter { $0.eventType.hasSuffix(".invocation") }.count == 2)
        }

        // MARK: - Block and failure

        @Test("A block is reported as a decision on the response, not as a failure")
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
            // ...but the event stream reports it as a verdict, matching Python, where
            // `_raise_if_blocked` runs after the response event is emitted.
            #expect(recorder.eventTypes.contains("middleware.guard.input.response"))
            #expect(!recorder.eventTypes.contains("middleware.guard.input.failure"))

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
                    "middleware.guard.input.invocation",
                    "middleware.guard.input.failure",
                ]
            )
            let failure = try #require(recorder.first(ofType: "middleware.guard.input.failure"))
            #expect(failure.payload["exception_name"] == .string("StubGuardrailError"))
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
