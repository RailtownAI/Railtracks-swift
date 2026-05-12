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
    var stepCount: Int = 0
    var steps: [RTSStamp] = []
    var nodeEvents: [RTSNodeEvent] = []
    var edgeEvents: [RTSEdgeEvent] = []
    
    internal var rootNodeID: UUID?
    
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
                // TODO: append message to event based on runID
                // TODO: what to do if nothing matches??... log/throw error?

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
                    log.warning("⚠️🎁 Could not find node event for message: \(message.id) - runID: \(runID)")
                    log.trace("⚠️🎁 message payload: \(message)")
                }
            } else {
                log.trace("🎁 Message: \(message.id) dropped due to no runID - payload: \(message)")
            }
        }
    }
    
    private func processNodeEvent(_ nodeEvent: RTSNodeEvent) {
        // TODO: find the associated Message and attach it to event, might be able to be completely dealt with in subscribeMessage
        log.trace("🎁 Appending nodeEvent: \(nodeEvent.name) - \(nodeEvent.stamp.event.identifier) to collector")
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
            generateJSONFile()
            cancellables.removeAll()
        }
    }
    
    private func generateJSONFile() {
        log.debug("generating JSON file for flow: \(flowName)(\(flowID))")
        log.debug("total nodes: \(nodeEvents.count)")
        log.debug("total edges: \(edgeEvents.count)")
        log.debug("total steps: \(steps.count)")
        
//        let graph = RTSFlowGraph.make(
//            flowName: flowName,
//            flowID: flowID,
//            nodeEvents: nodeEvents,
//            edgeEvents: edgeEvents,
//            rootNodeID: rootNodeID
//        )
        
        // TODO: determine JSON file name
        // TODO: create FlowGraph instance and serialize it
    }
}
