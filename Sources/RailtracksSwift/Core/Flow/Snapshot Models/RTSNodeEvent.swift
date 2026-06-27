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
    let nodeType: RTSFlowNodeType
    let stamp: RTSStamp
    var input: RTSInput?
    var output: RTSOutput?
    var error: String?
    var runID: UUID?
    var messages: [RTSMessage] = []
    var provider: String = ""
    var model: String = ""
    /// Guardrail steps recorded for this node's invocation (agents only).
    var guardTraces: [RTSGuardrailTrace] = []

    init(
        nodeID: UUID,
        name: String,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        input: RTSInput? = nil,
        output: RTSOutput? = nil,
        error: String? = nil,
        runID: UUID? = nil,
        messages: [RTSMessage] = [],
        provider: String = "",
        model: String = "",
        guardTraces: [RTSGuardrailTrace] = []
    ) {
        self.id = nodeID
        self.name = name
        self.nodeType = nodeType
        self.stamp = stamp
        self.input = input
        self.output = output
        self.error = error
        self.runID = runID
        self.messages = messages
        self.provider = provider
        self.model = model
        self.guardTraces = guardTraces
    }
}
