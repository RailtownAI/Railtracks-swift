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
    let runID: RTSRunID?
    let stamp: RTSStamp
    let nodeType: RTSFlowNodeType
    let sourceNodeID: UUID?
    let targetNodeID: UUID
    let sourceName: String?
    let targetName: String
    var input: RTSInput?
    var output: RTSOutput?
    var error: String?
    /// The error's details for the trace, set on a failed finish event alongside `error`. The
    /// collector builds it from the node's `node.destruction` failure details, which keep the
    /// error's type and call site that the `error` string has lost.
    var failure: RTSEdgeFailure?
}

/// A failed edge's error as the trace writes it: Python's `Failure.encode` shape, which the v1
/// visualizer needs to show its error panel (a string `type` and `message`, or a `traceback`).
struct RTSEdgeFailure {
    /// The error's type name, such as `RTSError`: the events' `exception_name`.
    let type: String
    /// The error's description: the events' `exception_message`.
    let message: String
    /// Where an `RTSError` was thrown, as `thrown at <file>:<line> in <function>`. Swift has no
    /// stack trace to offer, and other errors carry no call site, so they have none.
    let traceback: String?

    init(_ error: Error) {
        let fields = RTSEventFailure.fields(from: error)
        self.type = fields.name
        self.message = fields.message
        self.traceback = RTSEventFailure.callSite(of: error)
    }

    /// The same values from a node event's failure details: the trace collector has those, not the
    /// error. The details' `""` for an error with no call site is the trace's `null`.
    init(_ details: RTSEventFailureDetails) {
        self.type = details.exceptionName
        self.message = details.exceptionMessage
        self.traceback = details.traceback.isEmpty ? nil : details.traceback
    }

    /// The `output` value of a failed edge in the trace.
    var traceContent: RTSGeneratedContent {
        RTSGeneratedContent(kind: .structure([
            "type": RTSGeneratedContent(kind: .string(type)),
            "message": RTSGeneratedContent(kind: .string(message)),
            "traceback": RTSGeneratedContent(kind: traceback.map { .string($0) } ?? .null),
        ]))
    }
}
