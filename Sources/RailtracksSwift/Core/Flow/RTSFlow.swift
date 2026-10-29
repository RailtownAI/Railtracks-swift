//
//  RTSFlow.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import Combine
import Synchronization
import RailtownLogger

/// Representation of Agent node in Railtracks pipeline
public class RTSFlow: @unchecked Sendable {
    let id: UUID = UUID()
    let title: String
    let savesTrace: Bool
    /// The most seconds a run may take, or `nil` for no limit. A run past it is cancelled and throws
    /// `RTSError.runTerminated(reason: .timeout(after:))` once it has unwound.
    ///
    /// Adjustable between runs. Each run reads it once, when it starts, so a change affects runs
    /// started afterwards; a run already going keeps the deadline it started with. A value that
    /// can't be timed (NaN, infinity, or more than about 31 years) means no limit.
    public var timeout: TimeInterval? {
        get {
            storedTimeout.withLock { $0 }
        }
        set {
            storedTimeout.withLock { $0 = newValue }
        }
    }
    /// Backs `timeout`. Locked because runs can overlap: one may read the value as it starts while
    /// the app sets it from another thread.
    private let storedTimeout: Mutex<TimeInterval?>
    /// Whether the first node failure stops the whole run, running siblings included, even when a
    /// parent would have caught the error. Such a run throws
    /// `RTSError.runTerminated(reason: .endOnError(nodeName:underlying:))`, naming the node that
    /// failed and carrying its error. Python's `end_on_error`.
    ///
    /// Adjustable between runs, like `timeout`: each run reads it once, when it starts.
    public var endOnError: Bool {
        get {
            storedEndOnError.withLock { $0 }
        }
        set {
            storedEndOnError.withLock { $0 = newValue }
        }
    }
    /// Backs `endOnError`, locked for the same reason as `storedTimeout`.
    private let storedEndOnError: Mutex<Bool>
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
    /// body starts, and `.completed`, `.failed` or `.cancelled` when it finishes. `.cancelled` means
    /// the run was stopped, by cancelling its task or by a timeout.
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
    ///   - timeout: The most seconds each run may take, from invoking its root node to that node
    ///     finishing. At the deadline the run is cancelled, and `run` throws
    ///     `RTSError.runTerminated(reason: .timeout(after:))` once it has unwound. No node starts
    ///     after the deadline, but a node body that ignores cancellation finishes its current call
    ///     first, so `run` can return later than the deadline. Defaults to `nil`, no limit, as in
    ///     Python's `Flow(timeout=None)`.
    ///   - endOnError: When true, the first node failure stops the whole run, running siblings
    ///     included, and `run` throws `RTSError.runTerminated(reason: .endOnError(…))` naming that
    ///     node. Guardrail blocks count. Defaults to `false`, as in Python.
    public init(
        title: String,
        savesTrace: Bool = true,
        savesEvents: Bool? = nil,
        emitsEvents: Bool = true,
        signpostEmitter: (any RTSSignpostEmitting)? = nil,
        timeout: TimeInterval? = nil,
        endOnError: Bool = false
    ) {
        self.title = title
        self.savesTrace = savesTrace
        self.storedTimeout = Mutex(timeout)
        self.storedEndOnError = Mutex(endOnError)
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
        let settings = currentRunSettings()
        let startedAt = emitSessionStarted(entryPointName: agent.agentName, settings: settings)
        let (nodeInvoker, collector, subscriptions) = await startCollecting(settings: settings)
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
            emitSessionCompleted(startedAt: startedAt, error: error, settings: settings)
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
            let output = try await withRunStops(settings, stop: nodeInvoker.runStop) { [input] in
                try await nodeInvoker.invokeAgent(agent, input: input, session: session)
            }
            guard case let .string(result) = output[agent.outputKeyResult] else {
                throw RTSError.missingOutput("Agent \(agent.agentName) missing result")
            }
            outcome = .success(result)
        } catch {
            let reported = RTSRunCancellation.normalized(
                error,
                stopReason: nodeInvoker.runStop.reason
            )
            outcome = .failure(reported)
            reportFailure(reported)
        }
        await collector.awaitCompletion()
        _ = subscriptions       // keep alive until the run completes
        emitSessionCompleted(startedAt: startedAt, error: outcome.eventError, settings: settings)
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
        let settings = currentRunSettings()
        let startedAt = emitSessionStarted(entryPointName: node.name(), settings: settings)
        let (nodeInvoker, collector, subscriptions) = await startCollecting(settings: settings)
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
            let output = try await withRunStops(settings, stop: nodeInvoker.runStop) {
                try await nodeInvoker.invokeFunction(node, input: input, context: context)
            }
            outcome = .success(output)
        } catch {
            let reported = RTSRunCancellation.normalized(
                error,
                stopReason: nodeInvoker.runStop.reason
            )
            outcome = .failure(reported)
            reportFailure(reported)
        }
        await collector.awaitCompletion()
        _ = subscriptions       // keep alive until the run completes
        emitSessionCompleted(startedAt: startedAt, error: outcome.eventError, settings: settings)
        // Emission is isolated from execution, so the backlog is joined here rather than
        // interleaved with the run: subscribers cannot slow a node down, and the stream is
        // still complete by the time `run` returns.
        await flushEvents()
        return try outcome.get()
    }

    // MARK: - Run settings and stops

    /// The flow's adjustable settings, read once at the start of a run. The run keeps these even if
    /// the app changes `timeout` or `endOnError` while it's going.
    private func currentRunSettings() -> RunSettings {
        RunSettings(timeout: RTSFlow.effectiveTimeout(timeout), endOnError: endOnError)
    }

    /// The longest timeout a run will time, in seconds: about 31 years. Anything longer is no limit
    /// in practice, and far beyond it `Duration.seconds` traps.
    static let maximumTimeout: TimeInterval = 1_000_000_000

    /// `timeout` as a run can use it. A value that can't be timed, NaN, infinity or anything past
    /// `maximumTimeout`, means no limit: `Duration.seconds` traps on it, and `session.started`
    /// couldn't encode it as JSON. Zero or less is kept, and times out at once.
    static func effectiveTimeout(_ timeout: TimeInterval?) -> TimeInterval? {
        guard let timeout else {
            return nil
        }
        guard timeout.isFinite, timeout <= maximumTimeout else {
            log.warning("⏱️ timeout \(timeout) can't be timed; running with no limit")
            return nil
        }
        return timeout
    }

    /// Runs `work`, the run's root invocation, so that a stop from inside the run can end it: the
    /// run's timeout, or a node failing under `endOnError`.
    ///
    /// With neither set, `work` runs directly. Otherwise it runs in a task group next to a listener,
    /// which waits on `stop` and cancels the work once a stop is requested, plus a timer when there
    /// is a timeout. The timer and failing nodes both record their reason on `stop` **before** the
    /// listener cancels anything, so every node that then sees cancellation reports that reason
    /// rather than `.cancelled`. The group then waits for the work to unwind, so the trace is
    /// complete when this returns.
    ///
    /// A user cancel reaches every child: the timer and listener end without recording anything, and
    /// the work reports `.cancelled`. Work that finishes successfully despite a timeout returns its
    /// value, since nothing was actually stopped; after an end-on-error stop it throws anyway,
    /// because `endOnError` promises that a node failure fails the run.
    private func withRunStops<Output: Sendable>(
        _ settings: RunSettings,
        stop: RTSRunStop,
        _ work: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        guard settings.timeout != nil || stop.endsOnError else {
            return try await work()
        }
        let title = self.title
        return try await withThrowingTaskGroup(of: RunStep<Output>.self) { group in
            group.addTask {
                .finished(try await work())
            }
            group.addTask {
                await stop.stopRequested()
                return .stopRequested
            }
            if let timeout = settings.timeout {
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled, stop.request(.timeout(after: timeout)) {
                        log.info("⏱️ [\(title)] run passed its \(timeout)s timeout; cancelling it")
                    }
                    return .timerEnded
                }
            }
            do {
                for try await step in group {
                    switch step {
                    case .finished(let output):
                        group.cancelAll()
                        if let reason = stop.reason, case .endOnError = reason {
                            throw RTSError.runTerminated(reason: reason)
                        }
                        return output
                    case .stopRequested:
                        // Also reached when the listener's own task was cancelled; cancelling an
                        // already-cancelled group is harmless.
                        group.cancelAll()
                    case .timerEnded:
                        continue
                    }
                }
            } catch {
                // Once the run stopped itself, whatever the work throws is that stop. Nodes already
                // report it; this catches the failing node's own error when it is the root, and any
                // error raised outside every node.
                guard let reason = stop.reason,
                      RTSRunCancellation.terminationReason(of: error) == nil else {
                    throw error
                }
                throw RTSError.runTerminated(reason: reason)
            }
            // The work child always returns or throws, so the loop exits through one of those first.
            throw RTSError.runTerminated(reason: stop.reason ?? .cancelled)
        }
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
    private func emitSessionStarted(
        entryPointName: String,
        settings: RunSettings
    ) -> Date {
        let startedAt = RTSEventTimestamp.now()
        eventEmitter.emit(
            RTSSessionStartedEvent(
                sessionID: id.uuidString,
                flowName: title,
                flowID: RailtracksSwift.equalityHash(title),
                sessionName: nil,
                entryPointName: entryPointName,
                timeout: settings.timeout,
                endOnError: settings.endOnError,
                saveState: savesTrace,
                timestamp: startedAt
            )
        )
        return startedAt
    }

    /// Emits `session.completed`, deriving status from whether the run produced an error, and
    /// `termination_reason` from whether that error says the run was stopped, and `fatal` by
    /// Python's rule (``isFatal(_:endOnError:)``).
    ///
    /// One instant serves as both the event's `timestamp` and the end of the measured
    /// window, for the same reason ``emitSessionStarted(entryPointName:settings:)`` returns its own.
    private func emitSessionCompleted(
        startedAt: Date,
        error: Error?,
        settings: RunSettings
    ) {
        let completedAt = RTSEventTimestamp.now()
        let terminationReason = RTSRunCancellation.terminationReason(of: error)
            .map(RTSSessionTerminationReason.init)
        eventEmitter.emit(
            RTSSessionCompletedEvent(
                sessionID: id.uuidString,
                status: error == nil ? .success : .failure,
                // ANSI-stripped, mirroring Python's `format_error`.
                error: error.map(RTSSessionCompletedEvent.formatError),
                durationSeconds: completedAt.timeIntervalSince(startedAt),
                fatal: RTSFlow.isFatal(error, endOnError: settings.endOnError),
                terminationReason: terminationReason,
                timestamp: completedAt
            )
        )
    }

    /// Builds the per-run node invoker + graph collector and wires the
    /// `nodeStatusPublisher` subscriptions. The returned cancellables must be held
    /// for the duration of the run (they are kept alive by `run` awaiting completion).
    private func startCollecting(
        settings: RunSettings
    ) async -> (RTSNodeInvoker, RTSFlowGraphCollector, Set<AnyCancellable>) {
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
            eventEmitter: eventEmitter,
            runStop: RTSRunStop(endsOnError: settings.endOnError)
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
                statusOf(event, RTSFlow.finishedState(of: event))
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

    /// `session.completed`'s `fatal`, by Python's rule: the run failed, and either the flow ends on
    /// error or the error is itself fatal (`error is not None and (end_on_error or
    /// is_fatal(error))`). Swift has no fatal-error marker, so only the first half applies. A
    /// timeout or a cancel alone is not fatal; `termination_reason` reports those.
    ///
    /// One exception to Python's rule: a user cancel is never fatal, even under `endOnError`.
    /// Python has no user cancel, and an app stopping its own run isn't a failure.
    static func isFatal(_ error: Error?, endOnError: Bool) -> Bool {
        guard let error, endOnError else {
            return false
        }
        return !RTSRunCancellation.isCancellation(error)
    }

    /// The state a finish event reports. A node a stop cut short, whether by a cancel, a timeout or
    /// another node failing under `endOnError`, is `.cancelled`; a node that failed with its own
    /// error, including the one that triggered an end-on-error stop, is `.failed`.
    static func finishedState(of event: RTSNodeEvent) -> RTSNodeStatus.State {
        if event.terminationReason != nil {
            return .cancelled
        }
        guard let error = event.error else {
            return .completed
        }
        return .failed(error)
    }

}

// MARK: - RunSettings

/// `RTSFlow`'s adjustable settings as one run read them when it started.
private struct RunSettings {
    let timeout: TimeInterval?
    let endOnError: Bool
}

// MARK: - RunStep

/// What finished in `RTSFlow.withRunStops`'s task group.
private enum RunStep<Output: Sendable>: Sendable {
    /// The run's work returned.
    case finished(Output)
    /// The listener woke: a stop was requested, or its own task was cancelled.
    case stopRequested
    /// The timer ended, after requesting the timeout or because it was cancelled.
    case timerEnded
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
