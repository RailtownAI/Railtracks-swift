//
//  RTSNodeEvent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation

/// Node snapshot
struct RTSNodeEvent {
    let id: UUID
    let name: String
    let stamp: RTSStamp
    var output: RTSOutput?
    
    init(
        nodeID: UUID,
        name: String,
        stamp: RTSStamp,
        output: RTSOutput? = nil
    ) {
        self.id = nodeID
        self.name = name
        self.stamp = stamp
        self.output = output
    }
}
