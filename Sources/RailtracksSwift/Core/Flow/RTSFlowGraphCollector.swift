//
//  RTSFlowGraphCollector.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation
import Combine

/// Builds one run's flow-graph trace, and its Instruments signposts, from the run's observability
/// events.
///
/// It reads the emitter's typed tap (`RTSEventEmitter.observedEventPublisher`), keeps only its own
/// run's events (`runScope`), and translates them into the node and edge records `RTSFlowGraph.make`
/// turns into the trace: a creation record for each when the node's `node.invocation` arrives, and
/// a finish record for each at its `node.destruction`. See docs/trace-from-events.md.
actor RTSFlowGraphCollector {
    private enum CollectionState {
        case collecting
        case nodeComplete
        case edgeComplete
        case finished
    }

    /// What the collector knows about a node between its `node.creation` and `node.destruction`.
    private struct PendingNode {
        let creation: RTSNodeCreationEvent
        /// Reserved when `node.creation` arrives, so the step order is the order nodes were created.
        let creationStepIndex: Int
        var parentNodeID: UUID?
        var runID: RTSRunID?
        var edgeID: UUID?
        var creationStamp: RTSStamp?
        /// `node.invocation`'s `kwargs`, then each input guard transform in turn: the input the
        /// node's body received, which is what the edge records.
        var input: RTSInput = [:]
        var guardTraces: [RTSGuardrailTrace] = []
        /// The call's messages, from its latest `llm.response` or `llm.failure`.
        var messages: [RTSMessage] = []
    }

    let signpostEmitter: (any RTSSignpostEmitting)?
    var sessionID: UUID
    var flowName: String
    var startTime: Date?
    var endTime: Date?

    var nodeEvents: [RTSNodeEvent] = []
    var edgeEvents: [RTSEdgeEvent] = []

    internal var rootNodeID: UUID?
    internal var rootRunID: UUID?
    internal var ioIndex: Int = 0
    private var collectionState: CollectionState = .collecting

    private var pendingNodes: [UUID: PendingNode] = [:]
    /// The next step index. Steps are numbered as nodes are created and destroyed, from 0 per run,
    /// in the emitter's delivery order, which puts a parent's creation before its children's and a
    /// child's destruction before its parent's.
    private var nextStepIndex = 0

    // Outstanding (created-but-not-finished) node and edge invocations: +1 on create, -1 on finish.
    // Finalization is driven by the root's completion (see processNode/EdgeEvent), NOT these counters.
    // But because events are now processed in publish order, both counters MUST be zero by the time we
    // finalize. They are a self-check: a non-zero value at finalization means event ordering was
    // violated and the trace may be incomplete, so `finishCollection` logs a warning. See
    // docs/duplicate-node-id.md.
    private var nodeInProcessCounter = 0
    private var edgeInProcessCounter = 0

    private let outputFileURLSubject: CurrentValueSubject<Result<URL, Error>?, Never>
    private let completionStream: AsyncStream<Void>
    private let streamContinuation: AsyncStream<Void>.Continuation

    // This run's events, in the emitter's delivery order, drained by a single consumer
    // (`consumeEvents`). The emitter sends from one serial queue and the sink yields synchronously,
    // so yield order is delivery order.
    private let eventStream: AsyncStream<any RTSObservabilityEvent>
    private let eventContinuation: AsyncStream<any RTSObservabilityEvent>.Continuation

    nonisolated(unsafe) var cancellables: Set<AnyCancellable> = []

    /// - Parameter runScope: The run's `RTSEventEmitter.currentRunScope`. Events from anywhere
    ///   else, another run on the same flow or a session event, are ignored.
    init(
        flowName: String,
        sessionID: UUID,
        eventPublisher: AnyPublisher<RTSObservedEvent, Never>,
        runScope: UUID,
        outputFileURLSubject: CurrentValueSubject<Result<URL, Error>?, Never>,
        signpostEmitter: (any RTSSignpostEmitting)? = nil
    ) {
        self.sessionID = sessionID
        self.flowName = flowName
        self.outputFileURLSubject = outputFileURLSubject
        self.signpostEmitter = signpostEmitter
        (self.completionStream, self.streamContinuation) = AsyncStream<Void>.makeStream()
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(
            of: (any RTSObservabilityEvent).self
        )

        // The sink runs on the emitter's delivery queue, so it only filters and yields. It captures
        // the continuation (Sendable), not self.
        log.debug("🎁 setup observability event collector")
        eventPublisher
            .sink { [eventContinuation] observed in
                guard observed.runScope == runScope else {
                    return
                }
                eventContinuation.yield(observed.event)
            }
            .store(in: &cancellables)
    }

    deinit {
        cancellables.removeAll()
    }

    func setup() {
        startTime = Date()
        // Single ordered consumer. Started here (not in init) so `self` is fully initialized; any
        // events published before this point are buffered by the stream and drained in order.
        Task { [weak self] in
            await self?.consumeEvents()
        }
    }

    /// Drains the run's events in delivery order, one at a time. Exits when `finishCollection`
    /// finishes the stream.
    private func consumeEvents() async {
        for await event in eventStream {
            await process(event)
        }
    }

    // MARK: - Events to records

    private func process(_ event: any RTSObservabilityEvent) async {
        switch event {
        case let creation as RTSNodeCreationEvent:
            processCreation(creation)
        case let invocation as RTSNodeInvocationEvent:
            await processInvocation(invocation)
        case let response as RTSGuardInputResponseEvent:
            processInputGuardResponse(response)
        case let failure as RTSGuardInputFailureEvent:
            recordGuardFailure(
                spatialParent: failure.spatialParent,
                railName: failure.railName,
                stage: .input,
                exceptionName: failure.exceptionName,
                exceptionMessage: failure.exceptionMessage
            )
        case let response as RTSGuardOutputResponseEvent:
            updatePendingNode(guardedBy: response.spatialParent) { node in
                node.guardTraces.append(
                    RTSGuardrailTrace(
                        railName: response.railName,
                        stage: .output,
                        decision: response.decision
                    )
                )
            }
        case let failure as RTSGuardOutputFailureEvent:
            recordGuardFailure(
                spatialParent: failure.spatialParent,
                railName: failure.railName,
                stage: .output,
                exceptionName: failure.exceptionName,
                exceptionMessage: failure.exceptionMessage
            )
        case let response as RTSLLMResponseEvent:
            // Each response's input is every message before its output, so the latest one holds
            // the whole call so far.
            updatePendingNode(calledBy: response.spatialParent) { node in
                node.messages = response.messageInput + (response.output.map { [$0] } ?? [])
            }
        case let failure as RTSLLMFailureEvent:
            // A failure's input is everything the call had accumulated when it threw.
            updatePendingNode(calledBy: failure.spatialParent) { node in
                node.messages = failure.messageInput
            }
        case let destruction as RTSNodeDestructionEvent:
            await processDestruction(destruction)
        default:
            break
        }
    }

    private func processCreation(_ creation: RTSNodeCreationEvent) {
        guard let nodeID = UUID(uuidString: creation.nodeID) else {
            log.warning("⚠️🎁 node.creation with an unreadable node id: \(creation.nodeID)")
            return
        }
        pendingNodes[nodeID] = PendingNode(creation: creation, creationStepIndex: takeStepIndex())
    }

    /// The node's creation records: its parent and run are known from here. The edge's input is
    /// pre-transform for now, and replaced as input guards transform it.
    private func processInvocation(_ invocation: RTSNodeInvocationEvent) async {
        guard case .node(let nodeIDText) = invocation.parent,
              let nodeID = UUID(uuidString: nodeIDText),
              var node = pendingNodes[nodeID],
              let runID = invocation.runID else {
            log.warning("⚠️🎁 node.invocation with no node.creation before it, or no run id")
            return
        }
        guard case .node(let parentIDText) = invocation.spatialParent else {
            return
        }
        let parentNodeID = parentIDText.flatMap(UUID.init(uuidString:))
        let name = node.creation.name
        let stampEvent: RTSStamp.Event
        if let parentNodeID {
            stampEvent = .create(pendingNodes[parentNodeID]?.creation.name ?? "", name)
        } else {
            stampEvent = .startCreate(name)
        }
        let creationStamp = RTSStamp(
            stepIndex: node.creationStepIndex,
            timestamp: node.creation.timestamp,
            event: stampEvent
        )
        // The root edge's id is the root's run id, which is the trace's `run_id`.
        let edgeID = parentNodeID == nil ? runID : UUID()
        node.parentNodeID = parentNodeID
        node.runID = runID
        node.edgeID = edgeID
        node.creationStamp = creationStamp
        node.input = invocation.kwargs
        pendingNodes[nodeID] = node

        await processNodeEvent(
            RTSNodeEvent(
                nodeID: nodeID,
                parentNodeID: parentNodeID,
                name: name,
                nodeType: node.creation.nodeType,
                stamp: creationStamp,
                provider: node.creation.provider,
                model: node.creation.model,
                hasInputGuardrail: node.creation.hasInputGuardrail,
                hasOutputGuardrail: node.creation.hasOutputGuardrail
            )
        )
        await processEdgeEvent(
            RTSEdgeEvent(
                id: edgeID,
                runID: runID,
                stamp: creationStamp,
                nodeType: node.creation.nodeType,
                sourceNodeID: parentNodeID,
                targetNodeID: nodeID,
                sourceName: parentNodeID.flatMap { pendingNodes[$0]?.creation.name },
                targetName: name,
                input: invocation.kwargs
            )
        )
    }

    private func processInputGuardResponse(_ response: RTSGuardInputResponseEvent) {
        updatePendingNode(guardedBy: response.spatialParent) { node in
            node.guardTraces.append(
                RTSGuardrailTrace(
                    railName: response.railName,
                    stage: .input,
                    decision: response.decision
                )
            )
            if let transformed = response.decision.transformedDictionary {
                node.input = transformed
            }
        }
        // The edge records what the body received, so its creation record follows the transform.
        guard case .nodeAndMiddleware(let nodeIDText, _) = response.spatialParent,
              let nodeID = UUID(uuidString: nodeIDText),
              let node = pendingNodes[nodeID],
              let index = edgeEvents.lastIndex(where: { $0.id == node.edgeID }) else {
            return
        }
        edgeEvents[index].input = node.input
    }

    private func recordGuardFailure(
        spatialParent: RTSEventSpatialParent,
        railName: String,
        stage: RTSGuardrailStage,
        exceptionName: String,
        exceptionMessage: String
    ) {
        updatePendingNode(guardedBy: spatialParent) { node in
            node.guardTraces.append(
                .error(
                    railName: railName,
                    stage: stage,
                    exceptionName: exceptionName,
                    exceptionMessage: exceptionMessage
                )
            )
        }
    }

    /// The node's finish records, edge first, as `invokeCore` published them.
    private func processDestruction(_ destruction: RTSNodeDestructionEvent) async {
        guard case .node(let nodeIDText) = destruction.parent,
              let nodeID = UUID(uuidString: nodeIDText),
              let node = pendingNodes.removeValue(forKey: nodeID),
              let edgeID = node.edgeID,
              let runID = node.runID else {
            log.warning("⚠️🎁 node.destruction for a node the collector never saw invoked")
            return
        }
        let name = node.creation.name
        let completionStamp = RTSStamp(
            stepIndex: takeStepIndex(),
            timestamp: destruction.timestamp,
            event: .finishExecution(name)
        )
        let output: RTSOutput?
        if destruction.failure == nil, case .object(let response)? = destruction.response {
            output = response
        } else {
            output = nil
        }
        let error = destruction.failure?.exceptionMessage

        await processEdgeEvent(
            RTSEdgeEvent(
                id: edgeID,
                runID: nil,
                stamp: completionStamp,
                nodeType: node.creation.nodeType,
                sourceNodeID: node.parentNodeID,
                targetNodeID: nodeID,
                sourceName: node.parentNodeID.flatMap { pendingNodes[$0]?.creation.name },
                targetName: name,
                input: node.input,
                output: output,
                error: error,
                failure: destruction.failure.map { RTSEdgeFailure($0) }
            )
        )
        await processNodeEvent(
            RTSNodeEvent(
                nodeID: nodeID,
                parentNodeID: node.parentNodeID,
                name: name,
                nodeType: node.creation.nodeType,
                stamp: completionStamp,
                input: node.input,
                output: output,
                error: error,
                runID: runID,
                runtime: destruction.durationSeconds,
                messages: node.messages,
                guardTraces: node.guardTraces,
                hasInputGuardrail: node.creation.hasInputGuardrail,
                hasOutputGuardrail: node.creation.hasOutputGuardrail
            )
        )
    }

    private func takeStepIndex() -> Int {
        let stepIndex = nextStepIndex
        nextStepIndex += 1
        return stepIndex
    }

    /// Updates the node a guardrail event belongs to: its spatial parent names the node.
    private func updatePendingNode(
        guardedBy spatialParent: RTSEventSpatialParent,
        _ update: (inout PendingNode) -> Void
    ) {
        guard case .nodeAndMiddleware(let nodeIDText, _) = spatialParent else {
            return
        }
        updatePendingNode(nodeIDText, update)
    }

    /// Updates the agent an `llm.*` event belongs to: its spatial parent names the agent.
    private func updatePendingNode(
        calledBy spatialParent: RTSEventSpatialParent,
        _ update: (inout PendingNode) -> Void
    ) {
        guard case .node(let nodeIDText?) = spatialParent else {
            return
        }
        updatePendingNode(nodeIDText, update)
    }

    private func updatePendingNode(_ nodeIDText: String, _ update: (inout PendingNode) -> Void) {
        guard let nodeID = UUID(uuidString: nodeIDText), var node = pendingNodes[nodeID] else {
            return
        }
        update(&node)
        pendingNodes[nodeID] = node
    }

    // MARK: - Records

    private func processNodeEvent(_ nodeEvent: RTSNodeEvent) async {
        log.trace("🎁 Appending nodeEvent: \(nodeEvent.name) - \(nodeEvent.stamp.event.identifier) to collector")

        // Record the node synchronously before any suspension point (defensive: keeps a
        // reentrant `finishCollection()` from ever serializing the graph without this node).
        nodeEvents.append(nodeEvent)

        var isCollectionFinished = false
        switch nodeEvent.stamp.event {
        case .startCreate:
            rootNodeID = nodeEvent.id
            nodeInProcessCounter += 1

        case .create:
            nodeInProcessCounter += 1

        case .finishExecution:
            // The node's messages are on its finish record; emit point events now while all
            // ancestor edge events are already in edgeEvents. This is synchronous — it snapshots
            // state and hands async cost/emit to a detached task, so the actor never suspends here.
            emitNodePointEvents(nodeEvent)
            nodeInProcessCounter -= 1

            // Finalize on the root node's finish.
            if nodeEvent.id == rootNodeID {
                switch collectionState {
                case .collecting:
                    collectionState = .nodeComplete
                case .edgeComplete:
                    collectionState = .finished
                    isCollectionFinished = true
                case .nodeComplete, .finished:
                    log.debug("☠️🎁 should not be processing node event if collector state is finished")
                }
            }
        }

        if isCollectionFinished {
            await finishCollection()
        }
    }

    private func processEdgeEvent(_ edgeEvent: RTSEdgeEvent) async {
        log.trace("🎁 Appending edgeEvent: \(edgeEvent.sourceName ?? "START")->\(edgeEvent.targetName) - \(edgeEvent.stamp.event.identifier) to collector")

        var isCollectionFinished = false
        switch edgeEvent.stamp.event {
        case .finishExecution:
            emitEdgePointEvents(edgeEvent)
            edgeInProcessCounter -= 1

            // Finalize on the root edge's finish (source == nil).
            guard edgeEvent.sourceNodeID == nil else { break }
            switch collectionState {
            case .collecting:
                collectionState = .edgeComplete
            case .nodeComplete:
                collectionState = .finished
                isCollectionFinished = true
            case .edgeComplete, .finished:
                log.debug("☠️🎁 should not be processing edge event if collector state is finished")
            }

        case .create, .startCreate:
            edgeInProcessCounter += 1
            if edgeEvent.sourceNodeID == nil {
                rootRunID = edgeEvent.runID ?? edgeEvent.id
            }
            let nodeIdentifier = edgeEvent.targetNodeID.uuidString
            let parentIdentifier = edgeEvent.sourceNodeID?.uuidString ?? ""
            let parentType: RTSFlowNodeType? = edgeEvent.sourceNodeID.flatMap { sourceID in
                edgeEvents.first(where: { $0.targetNodeID == sourceID })?.nodeType
            }
            log.debug("🎁 emitGraphNode: '\(edgeEvent.targetName)' nodeID=\(nodeIdentifier) parentID=\(parentIdentifier) nodeType=\(edgeEvent.nodeType.rawValue) parentType=\(parentType?.rawValue ?? "nil")")
            signpostEmitter?.emitGraphNode(
                nodeID: nodeIdentifier,
                parentID: parentIdentifier,
                sessionID: sessionID.uuidString,
                runID: rootRunID?.uuidString ?? edgeEvent.runID?.uuidString ?? edgeEvent.id.uuidString,
                nodeType: edgeEvent.nodeType,
                parentType: parentType,
                error: false,
                parentError: false,
                cost: 0,
                model: "",
                parentName: edgeEvent.sourceName ?? "",
                name: edgeEvent.targetName,
                startTime: edgeEvent.stamp.timestamp.timeIntervalSince1970
            )
        }
        edgeEvents.append(edgeEvent)

        if isCollectionFinished {
            await finishCollection()
        }
    }

    // MARK: - Completion

    /// Waits until the trace has been finalized, even when the calling task is cancelled.
    ///
    /// An `AsyncStream` loop ends as soon as its task is cancelled, so awaiting the stream directly
    /// would let a cancelled run return before its trace is written. The loop runs in an
    /// unstructured task instead, which doesn't inherit cancellation, and awaiting its `value` isn't
    /// interrupted by cancellation either.
    func awaitCompletion() async {
        let stream = completionStream
        let drain = Task {
            for await _ in stream {}
        }
        await drain.value
    }

    private func finishCollection() async {
        // Self-check: ordered consumption should leave both counters at zero; warn if not.
        if nodeInProcessCounter != 0 || edgeInProcessCounter != 0 {
            log.warning("⚠️🎁 finalizing with unbalanced in-process counters (node: \(nodeInProcessCounter), edge: \(edgeInProcessCounter)) — event ordering may have been violated and the trace may be incomplete")
        }
        endTime = Date()
        await generateJSONFile()
        cancellables.removeAll()
        streamContinuation.finish()
        eventContinuation.finish()
    }

    private func generateJSONFile() async {
        log.debug("🎁 generating JSON file for flow: \(flowName) | sessionID: \(sessionID))")
        log.debug("🎁 total nodes: \(nodeEvents.count)")
        log.debug("🎁 total edges: \(edgeEvents.count)")

        guard let rootNodeID = rootNodeID, let startTime = startTime, let endTime = endTime else {
            log.debug("☠️🎁 unable to generate JSON output from the flow due to missing data")
            return
        }

        let graph = await RTSFlowGraph.make(
            flowName: flowName,
            sessionID: sessionID,
            nodeEvents: nodeEvents,
            edgeEvents: edgeEvents,
            rootNodeID: rootNodeID,
            startTime: startTime.timeIntervalSince1970,
            endTime: endTime.timeIntervalSince1970
        )

        let encoder = JSONEncoder()
        #if DEBUG
        encoder.outputFormatting = .prettyPrinted
        #endif
        let filename = generateJSONFileName()
        let url = RailtracksSwift.flowGraphOutputDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension("json")
        do {
            let json = try encoder.encode(graph)
            log.trace("🎁 Messages: \(String(data: json, encoding: .utf8) ?? "<invalid JSON data>")")
            try FileManager.default.createDirectory(
                at: RailtracksSwift.flowGraphOutputDirectory,
                withIntermediateDirectories: true
            )
            try json.write(to: url, options: .atomic)
            log.debug("🎁 flow graph JSON written to \(url.path)")
            self.outputFileURLSubject.send(.success(url))
        } catch {
            log.debug("☠️🎁 unable to encode flow graph to json and write to file: \(url.path)")
            self.outputFileURLSubject.send(.failure(RTSError.writeFileFailed(url.path)))
        }
    }

    func generateJSONFileName() -> String {
        return "\(flowName)_\(sessionID.uuidString)"
    }
}
