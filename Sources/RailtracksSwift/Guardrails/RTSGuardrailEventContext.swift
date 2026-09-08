//
//  RTSGuardrailEventContext.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSGuardrailEventContext

/// What `RTSGuardrailRunner` needs in order to emit `middleware.guard.*` events.
///
/// The runner is a caseless enum of static functions with nowhere to hang state, and the
/// guardrail closures built in `RTSNodeInvoker.invokeAgent` erase the rail array before it
/// reaches `invokeCore` — so per-rail events can only be emitted from inside the runner,
/// with this passed in. It is optional at every call site: with no context the runner
/// behaves exactly as it did before and emits nothing.
struct RTSGuardrailEventContext {

    let emitter: RTSEventEmitter
    /// The agent invocation these rails are guarding. Becomes the events' spatial parent.
    let nodeID: UUID
    /// Scopes each rail's middleware type id to the agent that owns it.
    let agentName: String

    init(
        emitter: RTSEventEmitter,
        nodeID: UUID,
        agentName: String
    ) {
        self.emitter = emitter
        self.nodeID = nodeID
        self.agentName = agentName
    }

    /// Fails — yielding "no context", and therefore no events — when there is no emitter.
    ///
    /// Exists so a caller holding an optional emitter can pass it straight through in an
    /// expression position, rather than unwrapping and re-wrapping. Callers do not need to
    /// know that emission is optional at all.
    init?(
        emitter: RTSEventEmitter?,
        nodeID: UUID,
        agentName: String
    ) {
        guard let emitter else {
            return nil
        }
        self.init(
            emitter: emitter,
            nodeID: nodeID,
            agentName: agentName
        )
    }

    /// Announces the rail if it has not been seen yet, mints an invocation id, and returns
    /// a handle carrying the parentage its events share.
    func beginRail(
        stage: RTSGuardrailStage,
        index: Int,
        name: String
    ) -> RTSGuardrailRailEvents {
        // Swift's guardrail protocols carry no identity — `name` defaults to the *type*
        // name, so two instances of one guardrail type are indistinguishable. Scoping the
        // hash by agent, stage and position makes the id stable across invocations of the
        // same agent while keeping two instances of the same type apart. Uses the same hash
        // the trace uses for `flow_id`.
        let scope = "\(agentName).\(stage.phaseValue).\(index).\(name)"
        let typeID = RailtracksSwift.equalityHash(scope)
        emitter.emitMiddlewareCreationOnce(typeID: typeID, name: name)
        return RTSGuardrailRailEvents(
            emitter: emitter,
            parent: .middleware(
                middlewareTypeID: typeID,
                middlewareInvokeID: UUID().uuidString
            ),
            // `middlewareInvokeID` is nil: Swift has no nested middleware, so there is never
            // an intervening one between the rail and its node.
            spatialParent: .nodeAndMiddleware(
                nodeID: nodeID.uuidString,
                middlewareInvokeID: nil
            )
        )
    }
}

// MARK: - RTSGuardrailRailEvents

/// One rail's slice of the event stream — the parentage its events share, plus the emit
/// calls for each point in its lifecycle.
///
/// Note that a **block is not a failure**: it is reported by `emitResponse` with a
/// ``RTSGuardrailDecision/Action/block`` decision, and the resulting
/// `RTSError.guardrailBlocked` unwinds separately. The failure events cover only a rail's
/// `check` throwing. This mirrors Python, where `_raise_if_blocked` runs *after* the
/// response event is emitted.
struct RTSGuardrailRailEvents {

    fileprivate let emitter: RTSEventEmitter
    fileprivate let parent: RTSEventParent
    fileprivate let spatialParent: RTSEventSpatialParent

    // MARK: Input rails

    func emitInputInvocation(_ messageHistory: RTSInput) {
        emitter.emit(
            RTSGuardInputInvocationEvent(
                parent: parent,
                spatialParent: spatialParent,
                messageHistory: messageHistory
            )
        )
    }

    /// - Parameter unchanged: The value as the rail received it, recorded when the rail did
    ///   not transform it. Taking the fallback rather than the final value lets the caller
    ///   build the decision inline, so it is never built when there is nothing to emit.
    func emitInputResponse(
        unchanged: RTSInput,
        decision: RTSGuardrailDecision
    ) {
        emitter.emit(
            RTSGuardInputResponseEvent(
                parent: parent,
                spatialParent: spatialParent,
                messageHistory: decision.transformedDictionary ?? unchanged,
                decision: decision
            )
        )
    }

    func emitInputFailure(_ error: Error) {
        emitter.emit(
            RTSGuardInputFailureEvent.from(
                error: error,
                parent: parent,
                spatialParent: spatialParent
            )
        )
    }

    // MARK: Output rails

    func emitOutputInvocation(_ response: RTSOutput) {
        emitter.emit(
            RTSGuardOutputInvocationEvent(
                parent: parent,
                spatialParent: spatialParent,
                response: response
            )
        )
    }

    /// - Parameter unchanged: See ``emitInputResponse(unchanged:decision:)``.
    func emitOutputResponse(
        unchanged: RTSOutput,
        decision: RTSGuardrailDecision
    ) {
        emitter.emit(
            RTSGuardOutputResponseEvent(
                parent: parent,
                spatialParent: spatialParent,
                response: decision.transformedDictionary ?? unchanged,
                decision: decision
            )
        )
    }

    func emitOutputFailure(_ error: Error) {
        emitter.emit(
            RTSGuardOutputFailureEvent.from(
                error: error,
                parent: parent,
                spatialParent: spatialParent
            )
        )
    }
}
