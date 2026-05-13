//
//  RTSEdgeEvent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation

/// Edge snapshot
struct RTSEdgeEvent {
    let id: UUID
    let stamp: RTSStamp
    let sourceNodeID: UUID?
    let targetNodeID: UUID
    let sourceName: String?
    let targetName: String
    var input: RTSInput?
    var output: RTSOutput?
    var error: String?
}
