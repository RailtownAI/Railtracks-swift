//
//  RTSFlowGraphCollector.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation
import Combine

actor RTSFlowGraphCollector {
    private enum CollectionState {
        case collecting
        case nodeComplete
        case edgeComplete
        case finished
    }

    /// A node or edge event, merged into one ordered stream so the collector can process them in
    /// publish order (see `eventStream`).
    private enum IncomingEvent: Sendable {
        case node(RTSNodeEvent)
        case edge(RTSEdgeEvent)
    }

    let stampFactory: RTSStampFactory
    let signpostEmitter: (any RTSSignpostEmitting)?
    var sessionID: UUID
    var flowName: String
    var startTime: Date?
    var endTime: Date?

    var nodeEvents: [RTSNodeEvent] = []
    var edgeEvents: [RTSEdgeEvent] = []

    internal var rootNodeID: UUID?
    internal var rootRunID: UUID?
    internal var messageBuffer: [UUID: [RTSMessage]] = [:]
    internal var ioIndex: Int = 0
    private var collectionState: CollectionState = .collecting

    // Outstanding (created-but-not-finished) node and edge invocations: +1 on create, -1 on finish.
    // Finalization is driven by the root's completion (see processNode/EdgeEvent), NOT these counters.
    // But because events are now processed in publish order, both counters MUST be zero by the time we
    // finalize. They are a self-check: a non-zero value at finalization means event ordering was
    // violated and the trace may be incomplete, so `finishCollection` logs a warning. See
    // docs/duplicate-node-id.md.
    private var nodeInProcessCounter = 0
    private var edgeInProcessCounter = 0

    private let outputFileURLSubject: CurrentValueSubject<Result<URL, Error>?, Never>
    private let savesTrace: Bool
    private let completionStream: AsyncStream<Void>
    private let streamContinuation: AsyncStream<Void>.Continuation

    // All node/edge events funnel through this one ordered stream, drained by a single consumer
    // (`consumeEvents`), so they are processed in publish order. `PassthroughSubject.send` delivers to
    // its sink synchronously in send-order and each sink `yield`s synchronously — so yield-order ==
    // send-order, and a FIFO consumer restores the ordering the earlier task-per-event dispatch lost.
    private let eventStream: AsyncStream<IncomingEvent>
    private let eventContinuation: AsyncStream<IncomingEvent>.Continuation

    nonisolated(unsafe) var cancellables: Set<AnyCancellable> = []

    init(
        stampFactory: RTSStampFactory,
        flowName: String,
        sessionID: UUID,
        nodeEventPublisher: NodeEventPublishers,
        outputFileURLSubject: CurrentValueSubject<Result<URL, Error>?, Never>,
        savesTrace: Bool = true,
        signpostEmitter: (any RTSSignpostEmitting)? = nil
    ) {
        self.stampFactory = stampFactory
        self.sessionID = sessionID
        self.flowName = flowName
        self.outputFileURLSubject = outputFileURLSubject
        self.savesTrace = savesTrace
        self.signpostEmitter = signpostEmitter
        (self.completionStream, self.streamContinuation) = AsyncStream<Void>.makeStream()
        (self.eventStream, self.eventContinuation) = AsyncStream<IncomingEvent>.makeStream()

        // Sinks capture only the continuation (Sendable), not self, and yield into `eventStream`.
        log.debug("🎁 setup node event collectors")
        nodeEventPublisher.nodeCreateEventPublisher
            .sink { [eventContinuation] nodeEvent in
                eventContinuation.yield(.node(nodeEvent))
            }
            .store(in: &cancellables)
        nodeEventPublisher.nodeInvokeEventPublisher
            .sink { [eventContinuation] nodeEvent in
                eventContinuation.yield(.node(nodeEvent))
            }
            .store(in: &cancellables)

        log.debug("🎁 setup edge event collectors")
        nodeEventPublisher.edgeCreateEventPublisher
            .sink { [eventContinuation] edgeEvent in
                eventContinuation.yield(.edge(edgeEvent))
            }
            .store(in: &cancellables)
        nodeEventPublisher.edgeFinishEventPublisher
            .sink { [eventContinuation] edgeEvent in
                eventContinuation.yield(.edge(edgeEvent))
            }
            .store(in: &cancellables)
    }

    deinit {
        cancellables.removeAll()
    }

    func subscribeMessage(_ publisher: MessagePublisher) {
        let handler: @Sendable ([RTSMessage]) -> Void = { [weak self] messages in
            Task { [weak self] in
                await self?.processMessages(messages)
            }
        }
        publisher.messagePublisher
            .sink(receiveValue: handler)
            .store(in: &cancellables)
    }

    func setup() {
        startTime = Date()
        // Single ordered consumer. Started here (not in init) so `self` is fully initialized; any
        // events published before this point are buffered by the stream and drained in order.
        Task { [weak self] in
            await self?.consumeEvents()
        }
    }

    /// Drains the merged event stream in FIFO (publish) order, one event at a time. Exits when
    /// `finishCollection` finishes the stream.
    private func consumeEvents() async {
        for await event in eventStream {
            switch event {
            case .node(let nodeEvent):
                await processNodeEvent(nodeEvent)
            case .edge(let edgeEvent):
                await processEdgeEvent(edgeEvent)
            }
        }
    }

    private func processMessages(_ messages: [RTSMessage]) async {
        let nodeEventIndexDictionary: [UUID: Int] = self.nodeEvents.enumerated().reduce(into: [:]) {
            if let runID = $1.element.runID {
                $0[runID] = $1.offset
            }
        }

        for message in messages {
            if let runID = message.runID {
                if let index = nodeEventIndexDictionary[runID] {
                    nodeEvents[index].messages.append(message)
                    log.trace("🎁 Appending message: \(message.id) to node event: \(nodeEvents[index].stamp.event.identifier)")
                } else {
                    messageBuffer[runID, default: []].append(message)
                }
            } else {
                log.trace("🎁 Message: \(message.id) dropped due to no runID - payload: \(message)")
            }
        }
    }

    private func processNodeEvent(_ nodeEvent: RTSNodeEvent) async {
        log.trace("🎁 Appending nodeEvent: \(nodeEvent.name) - \(nodeEvent.stamp.event.identifier) to collector")

        var nodeEvent = nodeEvent
        if let runID = nodeEvent.runID,
           let bufferedMessages = messageBuffer.removeValue(forKey: runID) {
            log.trace("🎁 appending \(bufferedMessages.count) messages to nodeEvent: \(nodeEvent.name)")
            nodeEvent.messages = bufferedMessages
        }

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
            // Messages are attached (buffer flushed above); emit point events now
            // while all ancestor edge events are already in edgeEvents. This is
            // synchronous — it snapshots state and hands async cost/emit to a detached
            // task, so the actor never suspends here.
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

    func awaitCompletion() async {
        for await _ in completionStream {}
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
        guard savesTrace else {
            log.debug("🎁 savesTrace off — skipping trace write for flow: \(flowName)")
            return
        }
        if !messageBuffer.isEmpty {
            for message in messageBuffer.values.flatMap({ $0 }) {
                log.warning("⚠️🎁 Could not find node event for message: \(message.id) - runID: \(message.runID?.uuidString ?? "n/a")")
                log.trace("⚠️🎁 message payload: \(message)")
            }
        }
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
