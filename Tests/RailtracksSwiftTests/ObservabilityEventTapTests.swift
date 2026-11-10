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

private extension RTSObservedEvent {
    /// The event's wire type, or `node.executing` for the executing signal, so a test can list the
    /// internal stream in one line.
    var eventType: String {
        switch event {
        case .observability(let event):
            return event.eventType
        case .nodeExecuting:
            return "node.executing"
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
            let observedTypes = observed.compactMap { $0.event.observabilityEvent?.eventType }
            #expect(observedTypes == published.map { $0.eventType })

            // Session events are emitted outside the run's scope; everything else inside it,
            // with one scope per run.
            let sessionEvents = observed.filter { $0.eventType.hasPrefix("session.") }
            let nodeEvents = observed.filter { $0.eventType.hasPrefix("node.") }
            #expect(sessionEvents.count == 4)
            #expect(sessionEvents.allSatisfy { $0.runScope == nil })
            #expect(nodeEvents.allSatisfy { $0.runScope != nil })
            #expect(Set(nodeEvents.compactMap { $0.runScope }).count == 2)
        }

        /// The executing signal goes on the internal stream only, between the node's invocation and
        /// its destruction, in its run's scope.
        @Test("the executing signal is internal, and comes between invocation and destruction")
        func executingSignal() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let child = TapOrchestrator(nodeName: "Child") { _, _ in
                ["result": .string("child")]
            }
            let root = TapOrchestrator(nodeName: "Root") { input, context in
                try await context.call(child, input: input)
            }
            let flow = RTSFlow(title: "TapExecuting", savesTrace: false)
            let recorder = TapRecorder(flow.eventEmitter)

            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let observed = await recorder.observedEvents
            let nodeTypes = observed.map { $0.eventType }.filter { $0.hasPrefix("node.") }
            #expect(nodeTypes == [
                "node.creation", "node.invocation", "node.executing",
                "node.creation", "node.invocation", "node.executing",
                "node.response", "node.destruction",
                "node.response", "node.destruction",
            ])
            let creations = observed.compactMap { observed in
                observed.event.observabilityEvent as? RTSNodeCreationEvent
            }
            let signals = observed.compactMap { observed -> RTSNodeExecutingSignal? in
                guard case .nodeExecuting(let signal) = observed.event else {
                    return nil
                }
                return signal
            }
            #expect(signals.map { $0.nodeID.uuidString } == creations.map { $0.nodeID })
            let scopes = observed.filter { $0.eventType == "node.executing" }.map { $0.runScope }
            #expect(scopes.allSatisfy { $0 != nil })

            let published = await recorder.publishedEvents
            #expect(!published.contains { $0.eventType.contains("executing") })
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

        @Test("an invoker notices when it runs outside its run's scope")
        func lostRunScope() {
            let scope = UUID()
            let scoped = RTSNodeInvoker(sessionID: UUID(), runScope: scope)
            let unscoped = RTSNodeInvoker(sessionID: UUID())

            // Outside any binding, as after a `Task.detached` inside the run.
            #expect(scoped.hasLostRunScope)
            RTSEventEmitter.$currentRunScope.withValue(scope) {
                #expect(!scoped.hasLostRunScope)
            }
            RTSEventEmitter.$currentRunScope.withValue(UUID()) {
                #expect(scoped.hasLostRunScope)
            }
            // An invoker built without a scope, as tests build them, is never checked.
            #expect(!unscoped.hasLostRunScope)
        }

        /// A run that exits before its root exists, such as a failed session build, never sends the
        /// root's `node.destruction`, so it must cancel its collector, or the collector stays
        /// subscribed to the flow's emitter.
        @Test("a cancelled collector unsubscribes, completes its waiters and is released")
        func cancelledCollector() async throws {
            let subject = PassthroughSubject<RTSObservedEvent, Never>()
            weak var released: RTSFlowGraphCollector?
            do {
                let collector = RTSFlowGraphCollector(
                    flowName: "Cancelled",
                    sessionID: UUID(),
                    eventPublisher: subject.eraseToAnyPublisher(),
                    runScope: UUID(),
                    outputFileURLSubject: CurrentValueSubject(nil)
                )
                await collector.setup()
                released = collector
                // Let the consumer task start: once it is draining the stream it holds the
                // collector, as it does in a real run by the time a session build fails.
                try await Task.sleep(for: .milliseconds(50))

                await collector.cancel()
                await collector.awaitCompletion()
            }

            for _ in 0..<100 where released != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(released == nil)
        }

        /// Node statuses are built from the internal stream and work with events off, so a disabled
        /// emitter still feeds it. Only the public stream is off.
        @Test("a disabled emitter feeds the internal stream, not the public one")
        func disabledEmitter() async throws {
            let recorder = TapRecorder(RTSEventEmitter(sessionID: "session-1", isEnabled: false))

            recorder.emitter.emit(RTSNodeCreationEvent(nodeID: "n1", name: "Node", nodeType: .tool))
            recorder.emitter.emitNodeExecuting(RTSNodeExecutingSignal(nodeID: UUID()))
            recorder.emitter.emitMiddlewareCreationOnce(typeID: "rail", name: "Rail")

            let observed = await recorder.observedEvents
            #expect(observed.map { $0.eventType } == [
                "node.creation",
                "node.executing",
                "middleware.creation",
            ])
            #expect(await recorder.publishedEvents.isEmpty)
        }

        /// A stop's reason rides on `node.destruction`, off the wire: set for the nodes the stop
        /// ended, `nil` for one that failed on its own or succeeded.
        @Test("node.destruction carries the termination reason, off the wire")
        func terminationReason() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            struct OwnFailure: Error {
            }
            let succeeds = TapOrchestrator(nodeName: "Succeeds") { _, _ in
                ["result": .string("ok")]
            }
            let fails = TapOrchestrator(nodeName: "Fails") { _, _ in
                throw OwnFailure()
            }
            let root = TapOrchestrator(nodeName: "Root") { _, context in
                _ = try await context.call(succeeds, input: [:])
                _ = try? await context.call(fails, input: [:])
                // Waits for the stop rather than rethrowing, so the root deterministically ends
                // with the stop instead of racing it with the child's error.
                try await Task.sleep(for: .seconds(30))
                return ["result": .string("never")]
            }
            let flow = RTSFlow(title: "TapTermination", savesTrace: false, endOnError: true)
            let recorder = TapRecorder(flow.eventEmitter)

            _ = try? await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let observed = await recorder.observedEvents
            let destructions = observed.compactMap { observed in
                observed.event.observabilityEvent as? RTSNodeDestructionEvent
            }
            #expect(destructions.count == 3)
            // In order: Succeeds, Fails, then Root, which the end-on-error stop cut short.
            #expect(destructions[0].terminationReason == nil)
            #expect(destructions[1].terminationReason == nil)
            guard case .endOnError(let nodeName, _)? = destructions[2].terminationReason else {
                Issue.record("expected the root to carry the end-on-error stop")
                return
            }
            #expect(nodeName == "Fails")
            #expect(!destructions[2].encodePayload().keys.contains { $0.contains("termination") })
        }

        @Test("node.creation and guard events carry what the trace needs, off the wire")
        func internalProperties() async throws {
            let recorder = TapRecorder(RTSEventEmitter(sessionID: "session-1", isEnabled: true))
            let invoker = RTSNodeInvoker(sessionID: UUID(), eventEmitter: recorder.emitter)
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
                agentName: "Agent"
            )

            _ = try await invoker.invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: session
            )
            _ = try await invoker.invokeTool(TapTool(), input: [:])

            let observed = await recorder.observedEvents
            let events = observed.compactMap { $0.event.observabilityEvent }
            let creations = events.compactMap { $0 as? RTSNodeCreationEvent }
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
                events.compactMap { $0 as? RTSGuardInputResponseEvent }.first
            )
            #expect(guardResponse.railName == "Check")

            // None of it reaches the payload.
            let payloadKeys = Set(agentCreation.encodePayload().keys)
            #expect(
                payloadKeys == ["timestamp", "spatial_parent_type", "node_id", "name", "node_type"]
            )
        }

        /// An app subscriber to `eventPublisher` runs on a queue of its own, so one that blocks
        /// holds up only the public stream. Everything built from the internal stream, the node
        /// statuses here, keeps arriving. Were it on the emitter's delivery queue, the root's
        /// `.completed` status would wait behind it, and this test would time out.
        @Test("an app subscriber blocking on eventPublisher doesn't hold up the internal stream")
        func blockedAppSubscriberIsIsolated() async throws {
            let released = Mutex(false)
            let release = DispatchSemaphore(value: 0)
            let root = TapOrchestrator(nodeName: "Root") { _, _ in
                ["result": .string("done")]
            }
            let flow = RTSFlow(title: "TapIsolation", savesTrace: false)
            let blocking = flow.eventPublisher.sink { _ in
                if !released.withLock({ $0 }) {
                    release.wait()
                }
            }
            let rootCompleted = Mutex<RTSNodeStatus?>(nil)
            let statuses = flow.nodeStatusPublisher.sink { status in
                guard case .completed = status.state, status.parentNodeID == nil else {
                    return
                }
                rootCompleted.withLock { $0 = status }
            }

            // `run` joins the public stream's backlog before returning, so it waits for the
            // blocked subscriber: run it alongside, and release the subscriber once the status
            // is in, or after 5 seconds.
            let running = Task {
                try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            }
            for _ in 0..<250 where rootCompleted.withLock({ $0 }) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let status = rootCompleted.withLock { $0 }
            released.withLock { $0 = true }
            release.signal()

            #expect(
                status?.nodeName == "Root",
                "the root's status waited behind the app subscriber"
            )
            _ = try await running.value
            blocking.cancel()
            statuses.cancel()
        }
    }
}
