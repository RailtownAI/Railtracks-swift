//
//  ObservabilityEventTapTests.swift
//  RailtracksSwiftTests
//
//  The emitter's internal typed tap, which the trace collector reads: the same events as the
//  public stream, in the same order, each with the run that emitted it, plus the internal
//  properties the trace and the signposts need. See docs/trace-from-events.md.
//

import Combine
import Foundation
import Synchronization
import Testing
@testable import RailtracksSwift

/// Collects an emitter's typed tap and its public stream side by side.
private final class TapRecorder: Sendable {
    let emitter: RTSEventEmitter
    private let observed = Mutex<[RTSObservedEvent]>([])
    private let published = Mutex<[RTSEvent]>([])
    private let cancellables = Mutex<Set<AnyCancellable>>([])

    init(_ emitter: RTSEventEmitter) {
        self.emitter = emitter
        let observedCancellable = emitter.observedEventPublisher.sink { [weak self] event in
            self?.observed.withLock { $0.append(event) }
        }
        let publishedCancellable = emitter.eventPublisher.sink { [weak self] event in
            self?.published.withLock { $0.append(event) }
        }
        cancellables.withLock { $0 = [observedCancellable, publishedCancellable] }
    }

    /// Flushes first, since delivery is asynchronous.
    var observedEvents: [RTSObservedEvent] {
        get async {
            await emitter.flushDelivery()
            return observed.withLock { $0 }
        }
    }

    var publishedEvents: [RTSEvent] {
        get async {
            await emitter.flushDelivery()
            return published.withLock { $0 }
        }
    }
}

/// An orchestrator whose body is supplied as a closure.
private struct TapOrchestrator: RTSOrchestratorNode {
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

/// A tool that returns a fixed output.
private struct TapTool: RTSToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName = "Fixed"
    let toolDescription = "fixed tool"
    let parameterSchema = RTSToolSchema(parameters: [])
    let callableRoutine = RTSClosure { _ in
        ["result": .string("fixed")]
    }
}

extension RailtracksSwiftTestSuite {
    @Suite("Observability event tap", .serialized)
    struct ObservabilityEventTapTests {

        @Test("the tap carries the public stream's events, in order, scoped to their run")
        func sameEventsInOrder() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let child = TapOrchestrator(nodeName: "Child") { _, _ in
                ["result": .string("child")]
            }
            let root = TapOrchestrator(nodeName: "Root") { input, context in
                try await context.call(child, input: input)
            }
            let flow = RTSFlow(title: "TapOrder")
            let recorder = TapRecorder(flow.eventEmitter)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let observed = await recorder.observedEvents
            let published = await recorder.publishedEvents
            #expect(observed.map { $0.event.eventType } == published.map { $0.eventType })

            // Session events are emitted outside the run's scope; everything else inside it,
            // with one scope per run.
            let sessionEvents = observed.filter { $0.event.eventType.hasPrefix("session.") }
            let nodeEvents = observed.filter { $0.event.eventType.hasPrefix("node.") }
            #expect(sessionEvents.count == 4)
            #expect(sessionEvents.allSatisfy { $0.runScope == nil })
            #expect(nodeEvents.allSatisfy { $0.runScope != nil })
            #expect(Set(nodeEvents.compactMap { $0.runScope }).count == 2)
        }

        @Test("an event's scope is the run scope bound where it was emitted")
        func scopeFromTaskLocal() async throws {
            let recorder = TapRecorder(RTSEventEmitter(sessionID: "session-1", isEnabled: true))
            let scope = UUID()
            let event = RTSNodeCreationEvent(nodeID: "n1", name: "Node", nodeType: .tool)

            recorder.emitter.emit(event)
            RTSEventEmitter.$currentRunScope.withValue(scope) {
                recorder.emitter.emit(event)
            }

            let scopes = await recorder.observedEvents.map { $0.runScope }
            #expect(scopes == [nil, scope])
        }

        @Test("a disabled emitter taps nothing")
        func disabledEmitter() async throws {
            let recorder = TapRecorder(RTSEventEmitter(sessionID: "session-1", isEnabled: false))

            recorder.emitter.emit(RTSNodeCreationEvent(nodeID: "n1", name: "Node", nodeType: .tool))

            #expect(await recorder.observedEvents.isEmpty)
        }

        @Test("node.creation and guard events carry what the trace needs, off the wire")
        func internalProperties() async throws {
            let recorder = TapRecorder(RTSEventEmitter(sessionID: "session-1", isEnabled: true))
            let invoker = RTSNodeInvoker(
                stampFactory: RTSStampFactory(),
                sessionID: UUID(),
                eventEmitter: recorder.emitter
            )
            let check = RTSClosureInputGuardrail(name: "Check") { _ in
                .allow("fine")
            }
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: "gpt-4o"),
                name: "Agent",
                inputGuardrails: [check]
            )
            let session = RTSLLMSession(
                run: { _, _, _ in
                    "hello"
                },
                setSystemPrompt: { _, _ in },
                message: {
                    []
                },
                messageSubject: BufferedPassthroughSubject<[RTSMessage]>(),
                agentName: "Agent"
            )

            _ = try await invoker.invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: session
            )
            _ = try await invoker.invokeTool(TapTool(), input: [:])

            let observed = await recorder.observedEvents
            let creations = observed.compactMap { $0.event as? RTSNodeCreationEvent }
            let agentCreation = try #require(creations.first { $0.name == "Agent" })
            #expect(agentCreation.hasInputGuardrail)
            #expect(!agentCreation.hasOutputGuardrail)
            #expect(agentCreation.provider == "OpenAI")
            #expect(agentCreation.model == "gpt-4o")
            let toolCreation = try #require(creations.first { $0.name == "Fixed" })
            #expect(!toolCreation.hasInputGuardrail)
            #expect(toolCreation.provider == "")
            #expect(toolCreation.model == "")

            let guardResponse = try #require(
                observed.compactMap { $0.event as? RTSGuardInputResponseEvent }.first
            )
            #expect(guardResponse.railName == "Check")

            // None of it reaches the payload.
            let payloadKeys = Set(agentCreation.encodePayload().keys)
            #expect(
                payloadKeys == ["timestamp", "spatial_parent_type", "node_id", "name", "node_type"]
            )
        }
    }
}
