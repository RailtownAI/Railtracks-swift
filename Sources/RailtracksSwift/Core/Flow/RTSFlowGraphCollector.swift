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
    private var messageBuffer: [UUID: [RTSMessage]] = [:]
    private var collectionState: CollectionState = .collecting
    
    private let outputFileURLSubject: CurrentValueSubject<URL?, Never>
    private let completionStream: AsyncStream<Void>
    private let streamContinuation: AsyncStream<Void>.Continuation

    nonisolated(unsafe) var cancellables: Set<AnyCancellable> = []

    init(
        stampFactory: RTSStampFactory,
        flowName: String,
        sessionID: UUID,
        nodeEventPublisher: NodeEventPublishers,
        outputFileURLSubject: CurrentValueSubject<URL?, Never>,
        signpostEmitter: (any RTSSignpostEmitting)? = nil
    ) {
        self.stampFactory = stampFactory
        self.sessionID = sessionID
        self.flowName = flowName
        self.outputFileURLSubject = outputFileURLSubject
        self.signpostEmitter = signpostEmitter
        (self.completionStream, self.streamContinuation) = AsyncStream<Void>.makeStream()

        log.debug("🎁 setup create node event collector")
        nodeEventPublisher.nodeCreateEventPublisher
            .sink { nodeEvent in
                Task { [weak self] in
                    await self?.processNodeEvent(nodeEvent)
                }
            }
            .store(in: &cancellables)

        log.debug("🎁 setup invoke node event collector")
        nodeEventPublisher.nodeInvokeEventPublisher
            .sink { nodeEvent in
                Task { [weak self] in
                    await self?.processNodeEvent(nodeEvent)
                }
            }
            .store(in: &cancellables)

        log.debug("🎁 setup create edge event collector")
        nodeEventPublisher.edgeCreateEventPublisher
            .sink { edgeEvent in
                Task { [weak self] in
                    await self?.processEdgeEvent(edgeEvent)
                }
            }
            .store(in: &cancellables)

        log.debug("🎁 setup finish edge event collector")
        nodeEventPublisher.edgeFinishEventPublisher
            .sink { edgeEvent in
                Task { [weak self] in
                    await self?.processEdgeEvent(edgeEvent)
                }
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

        var isCollectionFinished = false
        switch nodeEvent.stamp.event {
        case .startCreate:
            rootNodeID = nodeEvent.id

        case .finishExecution:
            // Messages are attached (buffer flushed above); emit point events now
            // while all ancestor edge events are already in edgeEvents.
            emitNodePointEvents(nodeEvent)

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

        default:
            break
        }
        nodeEvents.append(nodeEvent)

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
        endTime = Date()
        await generateJSONFile()
        cancellables.removeAll()
        streamContinuation.finish()
    }

    private func generateJSONFile() async {
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
        do {
            let json = try encoder.encode(graph)
            log.trace("🎁 Messages: \(String(data: json, encoding: .utf8) ?? "<invalid JSON data>")")
            let url = RailtracksSwift.flowGraphOutputDirectory
                .appendingPathComponent(filename)
                .appendingPathExtension("json")
            try json.write(to: url)
            self.outputFileURLSubject.send(url)
        } catch {
            log.debug("☠️🎁 unable to encode flow graph to json and write to file: \(filename).json")
            // TODO: 5893 - throw error upward to app level instead of only capture in log here;
            // TODO: 5893 - log generation is side task from main execution, so would need to build independent error pipe
//            throw RTSError.writeFileFailed("Write to file \(filename) failed")
        }
    }

    func generateJSONFileName() -> String {
        return "\(flowName)_\(sessionID.uuidString)"
    }
}
