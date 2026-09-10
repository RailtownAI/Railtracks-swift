//
//  ObservabilityEmissionTests.swift
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

/// Minimal orchestrator whose body is supplied as a closure, so these tests exercise the
/// real invoker → emitter path with no LLM involved. Same shape as `FunctionNodeTests`.
private struct StubOrchestrator: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName: String
    let body: @Sendable (RTSInput, RTSRunContext) async throws -> RTSOutput

    func name() -> String {
        nodeName
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        try await body(input, context)
    }
}

private struct StubError: Error {
}

/// Collects every event a flow publishes, for assertions after the run.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RTSEvent] = []
    private var cancellable: AnyCancellable?

    init(_ publisher: AnyPublisher<RTSEvent, Never>) {
        cancellable = publisher.sink { [weak self] event in
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

// Serialized: these run a full `RTSFlow`, which touches process-global state
// (`flowGraphOutputDirectory`), so they must not run concurrently with each other.
extension RailtracksSwiftTestSuite {

    /// Phase 2 of the observability port: events actually being emitted from the flow.
    /// The model itself is covered by `ObservabilityEventTests` and friends.
    @Suite("Observability emission", .serialized)
    struct ObservabilityEmissionTests {

        // MARK: - Node and session lifecycle

        @Test("A run emits the full session and node lifecycle, in order")
        func lifecycleSequence() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                ["result": .string("done")]
            }
            let flow = RTSFlow(title: "EmitLifecycle")
            let recorder = EventRecorder(flow.eventPublisher)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            #expect(
                recorder.eventTypes == [
                    "session.started",
                    "node.creation",
                    "node.invocation",
                    "node.response",
                    "node.destruction",
                    "session.completed",
                ]
            )
        }

        @Test("session.started carries the flow's identity and configuration")
        func sessionStartedPayload() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let root = StubOrchestrator(nodeName: "EntryPoint") { _, _ in
                [:]
            }
            let flow = RTSFlow(title: "EmitIdentity", savesTrace: false)
            let recorder = EventRecorder(flow.eventPublisher)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let started = try #require(recorder.first(ofType: "session.started"))
            #expect(started.scopeType == .session)
            #expect(started.payload["flow_name"] == .string("EmitIdentity"))
            let expectedFlowID = RailtracksSwift.equalityHash("EmitIdentity")
            #expect(started.payload["flow_id"] == .string(expectedFlowID))
            #expect(started.payload["entry_point_name"] == .string("EntryPoint"))
            #expect(started.payload["save_state"] == .bool(false))
            #expect(started.payload["session_name"] == .null)
            #expect(started.payload["timeout"] == .null)
            // Every event in a run shares the session's scope id.
            #expect(Set(recorder.events.map { $0.scopeID }).count == 1)
        }

        @Test("session.completed reports success and a duration")
        func sessionCompletedSuccess() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            let flow = RTSFlow(title: "EmitSuccess")
            let recorder = EventRecorder(flow.eventPublisher)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["status"] == .string("success"))
            #expect(completed.payload["error"] == .null)
            guard case .number(let duration)? = completed.payload["duration_seconds"] else {
                Issue.record("duration_seconds should be a number")
                return
            }
            #expect(duration >= 0)
        }

        @Test("duration_seconds is exactly the span between the two session timestamps")
        func durationMatchesTimestampSpan() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            let flow = RTSFlow(title: "EmitDurationSpan")
            let recorder = EventRecorder(flow.eventPublisher)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let started = try #require(recorder.first(ofType: "session.started"))
            let completed = try #require(recorder.first(ofType: "session.completed"))
            guard case .number(let duration)? = completed.payload["duration_seconds"] else {
                Issue.record("duration_seconds should be a number")
                return
            }

            // The *payload* timestamps are the ones the duration is measured between, so
            // this is an equality rather than an approximation: a consumer subtracting them
            // must get `duration_seconds` back.
            //
            // Deliberately not the envelope's `stamp`. An envelope carries its own `now()`,
            // minted when the typed event is wrapped — a slightly later instant. Python has
            // the same duality (`make_session_event` defaults `Event.stamp` independently of
            // the payload's `timestamp`), so the two are kept separate rather than unified.
            let startedAt = try #require(payloadTimestamp(started))
            let completedAt = try #require(payloadTimestamp(completed))
            let span = completedAt.timeIntervalSince(startedAt)
            #expect(abs(span - duration) < 0.000_001)
        }

        /// The `timestamp` an event's own payload carries, as opposed to its envelope's `stamp`.
        private func payloadTimestamp(_ event: RTSEvent) -> Date? {
            guard let text = str(event.payload["timestamp"]) else {
                return nil
            }
            return RTSEventTimestamp.date(from: text)
        }

        // MARK: - Parentage

        @Test("A nested node's spatial parent is its caller's invocation id")
        func nestedParentage() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let child = StubOrchestrator(nodeName: "Child") { _, _ in
                ["result": .string("child")]
            }
            let root = StubOrchestrator(nodeName: "Root") { _, context in
                try await context.call(child, input: [:])
            }
            let flow = RTSFlow(title: "EmitParentage")
            let recorder = EventRecorder(flow.eventPublisher)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let creations = recorder.events(ofType: "node.creation")
            #expect(creations.count == 2)
            let rootCreation = try #require(
                creations.first { $0.payload["name"] == .string("Root") }
            )
            let childCreation = try #require(
                creations.first { $0.payload["name"] == .string("Child") }
            )
            let rootNodeID = try #require(str(rootCreation.payload["node_id"]))
            let childNodeID = try #require(str(childCreation.payload["node_id"]))
            #expect(rootNodeID != childNodeID)

            // The root has no caller; the child's caller is the root. This is what proves the
            // `currentInvocationID` task-local reaches the new emit path.
            let invocations = recorder.events(ofType: "node.invocation")
            let rootInvocation = try #require(
                invocations.first { $0.payload["parent_node_id"] == .string(rootNodeID) }
            )
            let childInvocation = try #require(
                invocations.first { $0.payload["parent_node_id"] == .string(childNodeID) }
            )
            #expect(rootInvocation.payload["spatial_parent_node_id"] == .null)
            #expect(childInvocation.payload["spatial_parent_node_id"] == .string(rootNodeID))
        }

        // MARK: - Failure

        @Test("A throwing node emits failure and destruction, and fails the session")
        func failurePath() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let root = StubOrchestrator(nodeName: "Boom") { _, _ in
                throw StubError()
            }
            let flow = RTSFlow(title: "EmitFailure")
            let recorder = EventRecorder(flow.eventPublisher)

            await #expect(throws: StubError.self) {
                _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            }

            #expect(
                recorder.eventTypes == [
                    "session.started",
                    "node.creation",
                    "node.invocation",
                    "node.failure",
                    // Destruction is emitted whether or not the body threw, so a node is never
                    // left without a terminal event.
                    "node.destruction",
                    "session.completed",
                ]
            )
            let failure = try #require(recorder.first(ofType: "node.failure"))
            #expect(failure.payload["exception_name"] == .string("StubError"))

            let destruction = try #require(recorder.first(ofType: "node.destruction"))
            #expect(destruction.payload["response"] == .null)

            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["status"] == .string("failure"))
            #expect(completed.payload["error"] != .null)
        }

        @Test("A session-build failure is still bracketed by a session.completed")
        func sessionBuildFailureIsBracketed() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            // `run(agent:…)` builds the session eagerly and throws *before* awaiting the
            // collector, so that path cannot rely on the shared emit at the end of the
            // function — it carries its own. An empty gateway makes the build fail.
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: "gpt-4o"),
                name: "Unbuildable"
            )
            let flow = RTSFlow(title: "EmitSessionBuildFailure")
            let recorder = EventRecorder(flow.eventPublisher)

            var thrown: Error?
            do {
                _ = try await flow.run(
                    agent: agent,
                    prompt: "hi",
                    gateway: RTSLLMGateway(apiKeys: [:])
                )
            } catch {
                thrown = error
            }
            #expect(thrown != nil)

            // No node ever ran, so the run is just the session pair — and crucially the
            // `completed` half is present rather than the run being left half-reported.
            #expect(recorder.eventTypes == ["session.started", "session.completed"])
            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["status"] == .string("failure"))
            #expect(completed.payload["error"] != .null)
        }

        @Test("Every exit path emits exactly one session.completed")
        func exactlyOneCompletionPerRun() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            // The invocation `catch` stores its error in `outcome` and falls through to the
            // shared emit, so it must not emit its own — that would double-report the run.
            let root = StubOrchestrator(nodeName: "Boom") { _, _ in
                throw StubError()
            }
            let flow = RTSFlow(title: "EmitSingleCompletion")
            let recorder = EventRecorder(flow.eventPublisher)

            await #expect(throws: StubError.self) {
                _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            }

            #expect(recorder.events(ofType: "session.started").count == 1)
            #expect(recorder.events(ofType: "session.completed").count == 1)
        }

        // MARK: - The flag

        @Test("emitsEvents: false publishes nothing")
        func emissionDisabled() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                ["result": .string("done")]
            }
            let flow = RTSFlow(title: "EmitDisabled", emitsEvents: false)
            let recorder = EventRecorder(flow.eventPublisher)

            let output = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            #expect(str(output["result"]) == "done")
            #expect(recorder.events.isEmpty)
        }

        @Test("The JSON trace is unaffected by whether events are emitted")
        func traceUnaffectedByEmission() async throws {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            func runAndLoadTrace(emitsEvents: Bool) async throws -> RTSFlowGraph {
                let root = StubOrchestrator(nodeName: "Root") { _, _ in
                    ["result": .string("done")]
                }
                let flow = RTSFlow(title: "EmitTraceParity", emitsEvents: emitsEvents)
                _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
                for await result in flow.outputFileURLPublisher.values {
                    let url = try result.get()
                    return try JSONDecoder().decode(RTSFlowGraph.self, from: Data(contentsOf: url))
                }
                throw StubError()
            }

            let withEvents = try await runAndLoadTrace(emitsEvents: true)
            let withoutEvents = try await runAndLoadTrace(emitsEvents: false)

            // Ids and timings differ per run; the structure must not.
            #expect(withEvents.runs.count == withoutEvents.runs.count)
            #expect(withEvents.runs[0].nodes.count == withoutEvents.runs[0].nodes.count)
            #expect(withEvents.runs[0].edges.count == withoutEvents.runs[0].edges.count)
            #expect(withEvents.runs[0].steps.count == withoutEvents.runs[0].steps.count)
            #expect(withEvents.runs[0].status == withoutEvents.runs[0].status)
        }
    }
}
