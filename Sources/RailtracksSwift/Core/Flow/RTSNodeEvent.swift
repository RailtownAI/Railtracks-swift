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
    var input: RTSInput?
    var output: RTSOutput?
    var error: String?
    var runID: UUID?

    init(
        nodeID: UUID,
        name: String,
        stamp: RTSStamp,
        input: RTSInput? = nil,
        output: RTSOutput? = nil,
        error: String? = nil,
        runID: UUID? = nil
    ) {
        self.id = nodeID
        self.name = name
        self.stamp = stamp
        self.input = input
        self.output = output
        self.error = error
        self.runID = runID
    }
}
