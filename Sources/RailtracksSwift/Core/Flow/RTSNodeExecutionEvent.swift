//
//  RTSNodeExecutionEvent.swift
//  RailtracksSwift
//

import Foundation

/// Announces that a node's body is about to run, after its input guardrails have completed.
///
/// Named `Event` because that is the vocabulary of the tier that produces it: `RTSNodeInvoker`
/// publishes events, and `RTSFlow` translates events into the `RTSNodeStatus` values a UI consumes.
/// Keying the name to the producing tier rather than to today's consumer means it survives the
/// collector picking this up later — which is plausible, since an explicit execution-start timestamp
/// would split guardrail latency from execution latency in the trace. (Today the trace measures
/// `runtime` around `execute` alone, so execution duration is already recorded and its start is
/// derivable as finish minus runtime.)
///
/// Carries only what the queued → executing transition needs. Reusing `RTSNodeEvent` would have meant
/// a 16-field trace model with eleven fields left at defaults and no way for a reader to tell which
/// ones mattered. It also carries an `RTSStamp`, and `RTSStampFactory` hands out the monotonic indices
/// the trace orders by — a type without one cannot perturb that ordering.
///
/// Deliberately absent from `NodeEventPublishers`: the collector does not consume it yet, and adding
/// it to that protocol would force every conformer to implement an unused member. Adding it later is
/// purely additive.
struct RTSNodeExecutionEvent: Sendable {
    let nodeID: UUID
    /// The invocation that triggered this one; `nil` at the flow root.
    let parentNodeID: UUID?
    let name: String
    let nodeType: RTSFlowNodeType
    let runID: RTSRunID
}
