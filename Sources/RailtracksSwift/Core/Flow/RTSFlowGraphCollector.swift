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
    
    private func processNodeEvent(_ nodeEvent: RTSNodeEvent) {
        // TODO: find the associated Message and attach it to event
        log.trace("🎁 Appending nodeEvent: \(nodeEvent.name) - \(nodeEvent.stamp.event.identifier) to collector")
        nodeEvents.append(nodeEvent)
    }
}
