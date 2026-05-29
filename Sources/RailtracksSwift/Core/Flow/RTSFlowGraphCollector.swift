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
    let signpostEmitter: any RTSSignpostEmitting
    var sessionID: UUID
    var flowName: String
    var startTime: Date?
    var endTime: Date?

    var nodeEvents: [RTSNodeEvent] = []
    var edgeEvents: [RTSEdgeEvent] = []

    internal var rootNodeID: UUID?
    private var messageBuffer: [UUID: [RTSMessage]] = [:]
    private var collectionState: CollectionState = .collecting

    private let completionStream: AsyncStream<Void>
    private let streamContinuation: AsyncStream<Void>.Continuation

    nonisolated(unsafe) var cancellables: Set<AnyCancellable> = []

    init(
        stampFactory: RTSStampFactory,
        flowName: String,
        nodeEventPublisher: NodeEventPublishers,
        signpostEmitter: any RTSSignpostEmitting
    ) {
        self.stampFactory = stampFactory
        self.sessionID = UUID()
        self.flowName = flowName
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
        case .finishExecution where edgeEvent.sourceNodeID == nil:
            switch collectionState {
            case .collecting:
                collectionState = .edgeComplete
            case .nodeComplete:
                collectionState = .finished
                isCollectionFinished = true
            case .edgeComplete, .finished:
                log.debug("☠️🎁 should not be processing edge event if collector state is finished")
            }

        default:
            // Edge create event — emit FlowEdge as soon as the parent→child
            // relationship is established, before the child even executes.
            if let sourceID = edgeEvent.sourceNodeID {
                signpostEmitter.emitEdge(
                    source: sourceID.uuidString,
                    target: edgeEvent.targetNodeID.uuidString,
                    runID: edgeEvent.id.uuidString
                )
            }
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
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(filename)
                .appendingPathExtension("json")
            try json.write(to: url)
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

// MARK: - Point event emission

extension RTSFlowGraphCollector {
    /// Emits `FlowGraphNode`, `FlowTreeNode`, and `FlowIO` for a finishing node.
    /// Called from `processNodeEvent` after the message buffer has been flushed,
    /// so `nodeEvent.messages` is complete and all ancestor edge events are
    /// already in `edgeEvents`.
    private func emitNodePointEvents(_ nodeEvent: RTSNodeEvent) {
        guard let runID = nodeEvent.runID else { return }

        let nodeIDStr = nodeEvent.id.uuidString
        let sessionIDStr = sessionID.uuidString
        let runIDStr = runID.uuidString
        let hasError = nodeEvent.error != nil
        let nodeTypeStr = nodeEvent.nodeType.rawValue

        // Parent info: find the edge create event pointing to this node
        let parentEdge = edgeEvents
            .first(where: { $0.targetNodeID == nodeEvent.id && $0.sourceNodeID != nil })
        let parentIDStr = parentEdge?.sourceNodeID?.uuidString ?? ""
        let parentName = parentEdge?.sourceName ?? ""
        let parentTypeStr = parentEdge?.nodeType.rawValue ?? ""
        
        // Latency: difference between the node's create and finish stamps
        let createStamp = nodeEvents
            .first(where: { $0.id == nodeEvent.id && $0.runID == nil })?.stamp.timestamp
        let latency = createStamp.map { nodeEvent.stamp.timestamp.timeIntervalSince($0) } ?? 0
        
        // Aggregate LLM metadata from messages that carry it
        let messagesWithMeta: [(RTSMessage, RTSMessageMetadata)] = nodeEvent.messages
            .compactMap {
                guard let meta = $0.metadata else { return nil }
                return ($0, meta)
            }
        let totalInputTokens = messagesWithMeta.compactMap { $0.1.inputTokenCount }.reduce(0, +)
        let totalOutputTokens = messagesWithMeta.compactMap { $0.1.tokenCount }.reduce(0, +)
        let lastMeta = messagesWithMeta.last?.1
        let model = lastMeta?.model ?? ""
        let provider = lastMeta?.providerName ?? ""

        // Ancestor chain: walk edgeEvents upward from this node to the root
        let ancestorChain = buildAncestors(for: nodeEvent.id)

        // FlowGraphNode — emitted for every node
        signpostEmitter.emitGraphNode(
            nodeID: nodeIDStr,
            parentID: parentIDStr,
            sessionID: sessionIDStr,
            runID: runIDStr,
            nodeType: nodeTypeStr,
            parentType: parentTypeStr,
            error: hasError,
            parentError: false,
            cost: 0,
            model: model,
            parentName: parentName,
            name: nodeEvent.name
        )

        // FlowTreeNode — skip root (no ancestors) and non-leaf tools
        // (tools that invoked children contribute no LLM metrics that
        // their leaf descendants don't already carry)
        let isRoot = ancestorChain.isEmpty
        let isTool = nodeEvent.nodeType == .tool
        let isNonLeafTool = isTool && edgeEvents.contains(where: { $0.sourceNodeID == nodeEvent.id })
        if !isRoot && !isNonLeafTool {
            signpostEmitter.emitTreeNode(
                nodeID: nodeIDStr,
                sessionID: sessionIDStr,
                runID: runIDStr,
                nodeType: nodeTypeStr,
                model: model,
                provider: provider,
                cost: 0,
                latency: latency,
                inputTokens: totalInputTokens,
                outputTokens: totalOutputTokens,
                error: hasError,
                ancestors: ancestorChain,
                name: nodeEvent.name
            )
        }

        // FlowIO — one event per LLM message, numbered per direction bucket
        var inputIdx = 0
        var outputIdx = 0
        for message in nodeEvent.messages {
            let isInput = message.role == .system || message.role == .user
            let direction = isInput ? "Input" : "Output"
            if isInput { inputIdx += 1 } else { outputIdx += 1 }
            let idx = isInput ? inputIdx : outputIdx
            let displayRole = "\(String(format: "%02d", idx)) \(message.role.rawValue)"
            let meta = message.metadata

            signpostEmitter.emitIO(
                nodeID: nodeIDStr,
                sessionID: sessionIDStr,
                runID: runIDStr,
                messageID: message.id.uuidString,
                source: "llm",
                direction: direction,
                role: message.role.rawValue,
                model: meta?.model ?? model,
                provider: meta?.providerName ?? provider,
                cost: 0,
                latency: isInput ? 0 : (meta?.generationTime ?? 0),
                inputTokens: isInput ? (meta?.inputTokenCount ?? 0) : 0,
                outputTokens: isInput ? 0 : (meta?.tokenCount ?? 0),
                displayRole: displayRole,
                toolName: nodeEvent.name,
                content: message.content.textValue
            )
        }
    }

    /// Walk `edgeEvents` upward from `nodeID` to the root, collecting ancestor
    /// names in root-first order. Stops when no incoming non-root edge is found.
    private func buildAncestors(for nodeID: UUID) -> [String] {
        var result: [String] = []
        var currentID = nodeID
        while let edge = edgeEvents
            .first(where: { $0.targetNodeID == currentID && $0.sourceNodeID != nil }),
              let sourceName = edge.sourceName,
              let sourceID = edge.sourceNodeID {
            result.insert(sourceName, at: 0)
            currentID = sourceID
        }
        return result
    }
}
