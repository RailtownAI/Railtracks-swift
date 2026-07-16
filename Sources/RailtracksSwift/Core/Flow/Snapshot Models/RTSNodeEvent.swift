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
    /// Measured execution time (seconds) for this invocation, set on finish events only (nil on create
    /// snapshots). Measured at the source with a monotonic clock — never negative, unlike reconstructing
    /// it from create/finish stamp deltas (which mispairs when a node id repeats across invocations).
    var runtime: TimeInterval?
    var messages: [RTSMessage] = []
    var provider: String = ""
    var model: String = ""
    /// Guardrail steps recorded for this node's invocation (agents only).
    var guardTraces: [RTSGuardrailTrace] = []
    /// Whether this node (agent) has input/output guardrails. Used only to decorate
    /// the name in signpost/Instruments output — not part of the JSON trace.
    var hasInputGuardrail: Bool = false
    var hasOutputGuardrail: Bool = false

    init(
        nodeID: UUID,
        name: String,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        input: RTSInput? = nil,
        output: RTSOutput? = nil,
        error: String? = nil,
        runID: UUID? = nil,
        runtime: TimeInterval? = nil,
        messages: [RTSMessage] = [],
        provider: String = "",
        model: String = "",
        guardTraces: [RTSGuardrailTrace] = [],
        hasInputGuardrail: Bool = false,
        hasOutputGuardrail: Bool = false
    ) {
        self.id = nodeID
        self.name = name
        self.nodeType = nodeType
        self.stamp = stamp
        self.input = input
        self.output = output
        self.error = error
        self.runID = runID
        self.runtime = runtime
        self.messages = messages
        self.provider = provider
        self.model = model
        self.guardTraces = guardTraces
        self.hasInputGuardrail = hasInputGuardrail
        self.hasOutputGuardrail = hasOutputGuardrail
    }
}
