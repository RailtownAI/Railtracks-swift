//
//  RTSNodeExecutionEvent.swift
//  RailtracksSwift
//

import Foundation

/// Announces that a node's body is about to run, after its input guardrails have completed.
///
/// Named `Event` because that is the vocabulary of the tier that produces it: `RTSNodeInvoker`
/// publishes events, and `RTSFlow` translates events into the `RTSNodeStatus` values a UI consumes.
/// The trace has no use for it: it is built from the observability events, and measures `runtime`
/// around `execute` alone, so execution's start is derivable as finish minus runtime. An explicit
/// execution-start in the trace, splitting guardrail latency from execution latency, would be an
/// observability event.
///
/// Carries only what the queued → executing transition needs. Reusing `RTSNodeEvent` would have meant
/// a 16-field model with eleven fields left at defaults and no way for a reader to tell which ones
/// mattered.
struct RTSNodeExecutionEvent: Sendable {
    let nodeID: UUID
    /// The invocation that triggered this one; `nil` at the flow root.
    let parentNodeID: UUID?
    let name: String
    let nodeType: RTSFlowNodeType
    let runID: RTSRunID
}
