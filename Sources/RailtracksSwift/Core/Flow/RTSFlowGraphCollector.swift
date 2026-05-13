//
//  RTSFlowGraphCollector.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation
import Combine

actor RTSFlowGraphCollector {
    let stampFactory: RTSStampFactory
    var flowID: UUID
    var flowName: String
    var sessionID: UUID?
    var startTime: Date?
    var endTime: Date?
    
    // TODO: assuming single flow -> single run for now;
    // TODO: if multiple run within a flow is allowed, will need to the followings in dictionary with run id as key
    var steps: [RTSStamp] = []  // TODO: populate steps properly and generate JSON from here instead of grabbing from fields in nodeEvents
    var nodeEvents: [RTSNodeEvent] = []
    var edgeEvents: [RTSEdgeEvent] = []
    
    internal var rootNodeID: UUID?
    private var messageBuffer: [UUID: [RTSMessage]] = [:]
    
    nonisolated(unsafe) var cancellables: Set<AnyCancellable> = []
    
    init(
        stampFactory: RTSStampFactory,
        flowID: UUID,
        flowName: String,
        nodeEventPublisher: NodeEventPublishers
    ) {
        self.stampFactory = stampFactory
        self.flowID = flowID
        self.flowName = flowName
        
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
    }
    
    deinit {
        cancellables.removeAll()
    }
    
    nonisolated func subscribeMessage(_ publisher: MessagePublisher) {
        publisher.messagePublisher
            .sink { messages in
                Task { [weak self] in
                    await self?.processMessages(messages)
                }
            }
            .store(in: &cancellables)
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
        var isFlowComepleted: Bool = false
        switch nodeEvent.stamp.event {
        case .startCreate:
            rootNodeID = nodeEvent.id
        case .finishExecution where nodeEvent.id == rootNodeID:
            isFlowComepleted = true
        default:
            break
        }
        nodeEvents.append(nodeEvent)
        if isFlowComepleted {
            await generateJSONFile()
            cancellables.removeAll()
        }
    }
    
    private func generateJSONFile() async {
        if !messageBuffer.isEmpty {
            for message in messageBuffer.values.flatMap({ $0 }) {
                log.warning("⚠️🎁 Could not find node event for message: \(message.id) - runID: \(message.runID?.uuidString ?? "n/a")")
                log.trace("⚠️🎁 message payload: \(message)")
            }
        }
        log.debug("🎁 generating JSON file for flow: \(flowName)(\(flowID))")
        log.debug("🎁 total nodes: \(nodeEvents.count)")
        log.debug("🎁 total edges: \(edgeEvents.count)")
        log.debug("🎁 total steps: \(steps.count)")
        
        let graph = RTSFlowGraph.make(
            flowName: flowName,
            flowID: flowID,
            nodeEvents: nodeEvents,
            edgeEvents: edgeEvents,
            rootNodeID: rootNodeID
        )
        
        let encoder = JSONEncoder()
        #if DEBUG
        // petty format cost extra storage and will be an issue when JSON file size is of concern
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
            // TODO: throw error upward to app level instead of only capture in log here
            log.debug("☠️🎁 unable to encode flow graph to json and write to file: \(filename).json")
        }
    }
    
    func generateJSONFileName() -> String {
        // TODO: implement json file name logic, assess permission of public for app-side injection
        return "output_json_log"
    }
}
