//
//  RTSFlowGraphCollector.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation

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
    var nodeEvent: [RTSNodeEvent] = []
    var edgeEvent: [RTSEdgeEvent] = []
    
    init(stampFactory: RTSStampFactory, flowID: UUID, flowName: String) {
        self.stampFactory = stampFactory
        self.flowID = flowID
        self.flowName = flowName
        
        // TODO: setup the collector by subscribe to event like node creation and append snapshots
    }
}
