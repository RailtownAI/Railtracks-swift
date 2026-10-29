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
    /// The error's details for the trace, set on a failed finish event alongside `error`. Built
    /// from the thrown error because its type and call site are gone once it's a string.
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
        self.traceback = (error as? RTSError).map { railtracksError in
            let context = railtracksError.context
            return "thrown at \(context.file):\(context.line) in \(context.function)"
        }
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
