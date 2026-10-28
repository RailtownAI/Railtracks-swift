//
//  RTSFlow.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import Combine
import RailtownLogger

/// Representation of Agent node in Railtracks pipeline
public class RTSFlow: @unchecked Sendable {
    let id: UUID = UUID()
    let title: String
    let savesTrace: Bool
    let signpostEmitter: any RTSSignpostEmitting
    private let outputFileURLSubject: CurrentValueSubject<Result<URL, Error>?, Never> = .init(nil)
    /// Publishes the outcome of the JSON trace write after each completed run.
    /// Emits `.success(url)` when the file is written, or `.failure(RTSError.writeFileFailed(path))`
    /// when encoding or writing fails, where the associated value is the attempted file path.
    /// Late subscribers receive the most recent result immediately.
    /// The initial `nil` state (no run completed yet) is filtered out.
    public var outputFileURLPublisher: AnyPublisher<Result<URL, Error>, Never> {
        outputFileURLSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    private let nodeStatusSubject = PassthroughSubject<RTSNodeStatus, Never>()
    /// Serial, so statuses arrive in the order the invoker produced them. Its purpose is the
    /// same as `RTSEventEmitter`'s delivery queue: these statuses are sent from sinks that run
    /// on `RTSNodeInvoker`'s thread while its publish lock is held, so delivering subscribers
    /// inline would let one slow app sink block every node in the flow from publishing.
    private let nodeStatusDeliveryQueue = DispatchQueue(
        label: "ai.railtown.railtracks.nodestatus"
    )
    /// Publishes a status event each time any node (agent or tool, including sub-agents) transitions
    /// state: `.queued` when it is created, `.executing` once its input guardrails have run and its
    /// body starts, and `.completed` or `.failed` when it finishes.
    ///
    /// Each status carries `parentNodeID` — the invocation that triggered it, `nil` at the flow root —
    /// so consumers can reconstruct the call tree. Ids are per-invocation, so a node invoked N times
    /// reports N distinct ids.
    ///
    /// Subscribers are delivered on a private serial queue, not on the invoking node's thread,
    /// so a slow sink here cannot slow the run down.
    public var nodeStatusPublisher: AnyPublisher<RTSNodeStatus, Never> {
        nodeStatusSubject
            .receive(on: nodeStatusDeliveryQueue)
            .eraseToAnyPublisher()
    }

    let eventEmitter: RTSEventEmitter
    /// Publishes the structured observability event stream — the Swift port of the Python
    /// engine's event pipeline. Each value is a session-scoped ``RTSEvent`` envelope whose
    /// `payload` carries one typed event (`node.*`, `session.*`, `middleware.guard.*`).
    ///
    /// Independent of the JSON trace: the two are produced side by side and neither feeds
    /// the other. Silent when the flow was built with `emitsEvents: false`.
    ///
    /// Subscribers are delivered on a private serial queue rather than on the invoking node's
    /// thread, so a slow sink cannot slow a run down — but delivery is therefore asynchronous.
    /// Each `run` joins that backlog before returning, so the stream is complete once a run
    /// ends; call ``flushEvents()`` if you need the same guarantee at any other moment, such
    /// as before tearing a subscriber down mid-flow.
    public var eventPublisher: AnyPublisher<RTSEvent, Never> {
        eventEmitter.eventPublisher
    }

    /// This flow's event log, or `nil` when it does not write one.
    ///
    /// Subscribed in `init`, so unlike an app-wired writer it cannot miss `session.started` —
    /// the "subscribe before `run`" contract simply does not apply to it. It closes its file on
    /// each `session.completed` and re-arms, so successive runs append to one
    /// `<session id>.jsonl` and every run's log is complete on its own.
    ///
    /// Read it for the file URL, line counts or drop counts:
    ///
    /// ```swift
    /// flow.eventWriter?.fileURLPublisher
    ///     .sink { result in /* … */ }
    ///     .store(in: &subscriptions)
    /// ```
    ///
    /// Successive runs give one bracket each. **Overlapping** runs do not: two `run` calls in
    /// flight on the same flow share a session id and therefore a file, so their events
    /// interleave into overlapping `session.started`/`session.completed` pairs. Nothing is lost
    /// — `stamp` and the node ids still separate them — but the file is no longer one session,
    /// and the writer logs a warning and counts it on `overlappingRunEventCount`. Use a flow per
    /// concurrent run if you need one session per file. (The flow-graph trace fares worse here:
    /// it is named per session too, so concurrent runs overwrite one another.)
    ///
    /// - Important: do not construct a second ``RTSEventWriter`` for a flow that already has
    ///   one. Both would resolve to the same `<session id>.jsonl` and interleave their writes.
    ///   Pass `savesEvents: false` if you want to own the writer yourself. Likewise avoid
    ///   ``RTSEventWriter/finish()`` here — it is terminal, so it would stop every later run on
    ///   this flow from being recorded.
    public let eventWriter: RTSEventWriter?

    /// Waits until every event published so far has been handed to subscribers.
    ///
    /// Events are delivered asynchronously so that observation cannot slow execution, which
    /// means a subscriber torn down immediately after a run can miss the tail of the stream —
    /// `session.completed` included. Call this first when that matters:
    ///
    /// ```swift
    /// _ = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
    /// await flow.flushEvents()
    /// await eventWriter.finish()
    /// ```
    ///
    /// Not needed to *read* an ``RTSEventWriter``'s file — that closes itself on
    /// `session.completed` and announces the file on its own publisher.
    public func flushEvents() async {
        await eventEmitter.flushDelivery()
    }

    /// - Parameters:
    ///   - title: Display name for the flow, included in the trace file name.
    ///   - savesTrace: When true (default), the run writes its JSON trace to
    ///     `flowGraphOutputDirectory`. Set false to run without persisting a trace (mirrors Python's
    ///     `rt.Flow(save_state=False)`) — used for internal sub-flows like the evaluation judge, whose
    ///     runs should not spill trace files. The completion lifecycle is unaffected.
    ///   - savesEvents: Whether the flow writes its observability event stream to a JSONL file in
    ///     `eventsOutputDirectory` through ``eventWriter``. Defaults to `nil`, meaning **follow
    ///     `savesTrace`** — the two artifacts usually want the same persistence policy, and it
    ///     is what keeps the evaluation judge's per-call sub-flows from spilling event logs the
    ///     same way it keeps them from spilling traces. Pass it explicitly when they should
    ///     diverge: `savesEvents: false` to own the writer yourself, or `true` on a trace-less
    ///     flow that still wants events. Ignored when `emitsEvents` is false.
    ///   - emitsEvents: When true (default), the run publishes observability events on
    ///     `eventPublisher`, matching the Python engine, which emits unless
    ///     `RAILTRACKS_DISABLE_EVENTS` is set. Set false to skip it entirely — payloads are
    ///     never built, so a flow with no event consumer pays no encoding cost.
    ///   - signpostEmitter: Emitter for Instruments signpost events. Defaults to a standard `RTSSignpostEmitter`.
    public init(
        title: String,
        savesTrace: Bool = true,
        savesEvents: Bool? = nil,
        emitsEvents: Bool = true,
        signpostEmitter: (any RTSSignpostEmitting)? = nil
    ) {
        self.title = title
        self.savesTrace = savesTrace
        self.signpostEmitter = signpostEmitter ?? RTSSignpostEmitter()
        // Held as a local as well: `self` cannot be used to reach the emitter until every
        // stored property is assigned, and the writer has to subscribe before `init` returns.
        let emitter = RTSEventEmitter(
            sessionID: id.uuidString,
            isEnabled: emitsEvents
        )
        self.eventEmitter = emitter
        if savesEvents ?? savesTrace, emitsEvents {
            let writer = RTSEventWriter()
            // Subscribing here is what makes the built-in log immune to the no-replay trap an
            // app-wired writer has to work around.
            writer.subscribe(to: emitter.eventPublisher)
            self.eventWriter = writer
        } else {
            self.eventWriter = nil
        }
    }

    /// Tears the built-in event log down when the flow goes away.
    ///
    /// Required, not tidiness: the writer holds two reference cycles that only `finish()` breaks.
    /// Its `Queue` stores the Combine subscription whose sink captures that same `Queue`, and its
    /// consumer task retains the writer across `for await` — a loop that ends only when the
    /// stream is finished. Without this, every flow that saves events would leak its writer, its
    /// queue and the queue's buffer for the life of the process.
    deinit {
        // A local copy, so the task captures the writer rather than a deinitializing `self`.
        guard let eventWriter else {
            return
        }
        Task {
            await eventWriter.finish()
        }
    }

    /// Runs the pipeline from the given root agent and returns its text result.
    ///
    /// Creates a fresh node invoker and graph collector, wires up event subscriptions,
    /// invokes the agent, then waits for the JSON trace file to finish writing before returning.
    ///
    /// - Parameters:
    ///   - agent: Root agent node to invoke.
    ///   - prompt: User prompt passed to the agent.
    ///   - gateway: Gateway used to build LLM sessions for the agent and any sub-agents.
    ///   - systemMessage: Optional system message applied to the agent's session before the prompt is sent.
    ///   - images: Optional images attached to the prompt for multimodal (vision) input. Requires a
    ///     vision-capable cloud model; ignored by on-device (AppleAI) agents.
    /// - Returns: The agent's text output.
    public func run(
        agent: some RTSAgentNode,
        prompt: String,
        gateway: RTSLLMGateway,
        systemMessage: String? = nil,
        images: [RTSImage] = []
    ) async throws -> String {
        let startedAt = emitSessionStarted(entryPointName: agent.agentName)
        let (nodeInvoker, collector, subscriptions) = await startCollecting()
        let onNewSession: @Sendable (RTSLLMSession) -> Void = { [collector] session in
            Task { await collector.subscribeMessage(session) }
        }

        let session: RTSLLMSession
        do {
            session = try gateway.session(
                invoker: nodeInvoker,
                agentNode: agent,
                onNewSession: onNewSession
            )
        } catch {
            // Session build failures (e.g. missingAPIKey) never reach the invocation
            // catch below, so report them here; control flow is unchanged — the error
            // still propagates immediately, before any node runs.
            RailtownLogger.captureRailtracks(
                error,
                flowTitle: title,
                properties: [RTSErrorReportProperty.railtracksVersion: RailtracksSwift.version],
                callSite: (error as? RTSError)?.railtownCallSite
            )
            // This path exits before `awaitCompletion()`, so it needs its own completion
            // event — otherwise a failed session build would leave the run unbracketed.
            emitSessionCompleted(startedAt: startedAt, error: error)
            await flushEvents()
            throw error
        }
        onNewSession(session)   // subscribe the root agent's own session

        var input = agent.inputs
        input[agent.inputKeyPrompt] = .string(prompt)
        if let systemMessage {
            input[agent.inputKeySystemMessage] = .string(systemMessage)
        }
        if !images.isEmpty {
            input[agent.inputKeyImages] = .array(images.map { .image($0) })
        }

        let outcome: Result<String, Error>
        do {
            let output = try await nodeInvoker.invokeAgent(agent, input: input, session: session)
            guard case let .string(result) = output[agent.outputKeyResult] else {
                throw RTSError.missingOutput("Agent \(agent.agentName) missing result")
            }
            outcome = .success(result)
        } catch {
            let reported = RTSRunCancellation.normalized(error)
            outcome = .failure(reported)
            reportFailure(reported)
        }
        await collector.awaitCompletion()
        _ = subscriptions       // keep alive until the run completes
        emitSessionCompleted(startedAt: startedAt, error: outcome.eventError)
        // Emission is isolated from execution, so the backlog is joined here rather than
        // interleaved with the run: subscribers cannot slow a node down, and the stream is
        // still complete by the time `run` returns.
        await flushEvents()
        return try outcome.get()
    }

    /// Runs the pipeline from an orchestrating function node as the root. The node
    /// may invoke agents and other orchestrators through the provided `RTSRunContext`,
    /// all of which are traced as its children.
    ///
    /// - Returns: the function node's raw output.
    public func run(
        _ node: some RTSOrchestratorNode,
        input: RTSInput,
        gateway: RTSLLMGateway
    ) async throws -> RTSOutput {
        let startedAt = emitSessionStarted(entryPointName: node.name())
        let (nodeInvoker, collector, subscriptions) = await startCollecting()
        let onNewSession: @Sendable (RTSLLMSession) -> Void = { [collector] session in
            Task { await collector.subscribeMessage(session) }
        }

        let context = RTSRunContext(
            invoker: nodeInvoker,
            makeSession: { agent in
                try gateway.session(
                    invoker: nodeInvoker,
                    agentNode: agent,
                    onNewSession: onNewSession
                )
            },
            onNewSession: onNewSession,
            createdBy: node
        )

        let outcome: Result<RTSOutput, Error>
        do {
            outcome = .success(try await nodeInvoker.invokeFunction(node, input: input, context: context))
        } catch {
            let reported = RTSRunCancellation.normalized(error)
            outcome = .failure(reported)
            reportFailure(reported)
        }
        await collector.awaitCompletion()
        _ = subscriptions       // keep alive until the run completes
        emitSessionCompleted(startedAt: startedAt, error: outcome.eventError)
        // Emission is isolated from execution, so the backlog is joined here rather than
        // interleaved with the run: subscribers cannot slow a node down, and the stream is
        // still complete by the time `run` returns.
        await flushEvents()
        return try outcome.get()
    }

    // MARK: - Error reporting

    /// Fire-and-forget upload of a failed run to Conductr; a no-op unless the app configured
    /// RailtownLogger with auto-capture enabled. The caller still rethrows `error` unchanged.
    ///
    /// A run the app cancelled itself is not a bug, so it is not reported.
    private func reportFailure(_ error: Error) {
        guard !RTSRunCancellation.isCancellation(error) else {
            return
        }
        RailtownLogger.captureRailtracks(
            error,
            flowTitle: title,
            properties: [RTSErrorReportProperty.railtracksVersion: RailtracksSwift.version],
            callSite: (error as? RTSError)?.railtownCallSite
        )
    }

    // MARK: - Session events

    /// Emits `session.started` and returns the instant it was stamped with.
    ///
    /// The return value is what makes the pair self-consistent: `session.completed`
    /// measures its duration from *exactly* this event's `timestamp`, so
    /// `completed.timestamp - started.timestamp == duration_seconds` holds precisely
    /// rather than approximately. Taking a separate `Date()` at the call site would leave
    /// the two a hair apart.
    ///
    /// Mirrors the Python engine, which emits one `SessionStarted` per **top-level run**
    /// (`interaction/_call.py`) and starts its clock immediately after, while the session id
    /// itself stays constant for the life of the session object. So two runs on one
    /// `RTSFlow` legitimately share a `scope_id` and are told apart by `entry_point_name`
    /// and their timestamps.
    private func emitSessionStarted(entryPointName: String) -> Date {
        let startedAt = RTSEventTimestamp.now()
        eventEmitter.emit(
            RTSSessionStartedEvent(
                sessionID: id.uuidString,
                flowName: title,
                flowID: RailtracksSwift.equalityHash(title),
                sessionName: nil,
                entryPointName: entryPointName,
                // Swift has no flow-level timeout or end-on-error setting; Python's
                // equivalents come from its executor config.
                timeout: nil,
                endOnError: false,
                saveState: savesTrace,
                timestamp: startedAt
            )
        )
        return startedAt
    }

    /// Emits `session.completed`, deriving status from whether the run produced an error.
    ///
    /// One instant serves as both the event's `timestamp` and the end of the measured
    /// window, for the same reason ``emitSessionStarted(entryPointName:)`` returns its own.
    private func emitSessionCompleted(
        startedAt: Date,
        error: Error?
    ) {
        let completedAt = RTSEventTimestamp.now()
        eventEmitter.emit(
            RTSSessionCompletedEvent(
                sessionID: id.uuidString,
                status: error == nil ? .success : .failure,
                // ANSI-stripped, mirroring Python's `format_error`.
                error: error.map(RTSSessionCompletedEvent.formatError),
                durationSeconds: completedAt.timeIntervalSince(startedAt),
                timestamp: completedAt
            )
        )
    }

    /// Builds the per-run node invoker + graph collector and wires the
    /// `nodeStatusPublisher` subscriptions. The returned cancellables must be held
    /// for the duration of the run (they are kept alive by `run` awaiting completion).
    private func startCollecting() async -> (RTSNodeInvoker, RTSFlowGraphCollector, Set<AnyCancellable>) {
        // Warm the pricing map now (fire-and-forget) so the first per-node signpost cost
        // calculation doesn't pay the remote/disk fetch. It runs concurrently with the
        // flow and finishes long before the first node completes an LLM round-trip;
        // respects the TTL cache, so it's a cheap no-op on subsequent runs.
        Task { await RTSCostCalculator.shared.preloadPricing() }

        let stampFactory = RTSStampFactory()
        let nodeInvoker = RTSNodeInvoker(
            stampFactory: stampFactory,
            sessionID: id,
            signpostEmitter: signpostEmitter,
            eventEmitter: eventEmitter
        )

        var subscriptions = Set<AnyCancellable>()
        // Three lifecycle signals, one per state transition. `.queued` covers the window where input
        // guardrails run — brief for most nodes, but a model-backed guardrail makes it visible.
        let statusOf: @Sendable (RTSNodeEvent, RTSNodeStatus.State) -> RTSNodeStatus = { event, state in
            RTSNodeStatus(
                nodeID: event.id,
                parentNodeID: event.parentNodeID,
                nodeName: event.name,
                nodeType: event.nodeType,
                state: state,
                runID: event.runID
            )
        }
        nodeInvoker.nodeCreateEventPublisher
            .map { statusOf($0, .queued) }
            .sink { [weak self] in self?.nodeStatusSubject.send($0) }
            .store(in: &subscriptions)
        nodeInvoker.nodeExecutionEventPublisher
            .map { event in
                RTSNodeStatus(
                    nodeID: event.nodeID,
                    parentNodeID: event.parentNodeID,
                    nodeName: event.name,
                    nodeType: event.nodeType,
                    state: .executing,
                    runID: event.runID
                )
            }
            .sink { [weak self] in self?.nodeStatusSubject.send($0) }
            .store(in: &subscriptions)
        nodeInvoker.nodeInvokeEventPublisher
            .map { event -> RTSNodeStatus in
                let state: RTSNodeStatus.State = event.error == nil
                    ? .completed
                    : .failed(event.error ?? "unknown")
                return statusOf(event, state)
            }
            .sink { [weak self] in self?.nodeStatusSubject.send($0) }
            .store(in: &subscriptions)

        let collector = RTSFlowGraphCollector(
            stampFactory: stampFactory,
            flowName: title,
            sessionID: id,
            nodeEventPublisher: nodeInvoker,
            outputFileURLSubject: outputFileURLSubject,
            savesTrace: savesTrace,
            signpostEmitter: signpostEmitter
        )
        await collector.setup()
        return (nodeInvoker, collector, subscriptions)
    }

}

// MARK: - Result

private extension Result {
    /// The failure value, or `nil` on success — for handing a run's outcome to
    /// `session.completed` without unwrapping the success value.
    var eventError: Error? {
        guard case .failure(let error) = self else {
            return nil
        }
        return error
    }
}
