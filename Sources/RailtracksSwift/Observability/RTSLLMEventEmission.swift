//
//  RTSLLMEventEmission.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-08.
//

import Foundation

// MARK: - RTSLLMEventEmission

/// Turns an agent invocation's message log into the `llm.*` event family.
///
/// Unlike every other family, these are **reconstructed rather than observed**: Conduit runs
/// the whole tool-calling loop inside one `ChatSession.send`, so Swift only ever sees the
/// messages it left behind. `RTSLLMRoundTrip` does the walk; this maps each trip onto the
/// events, and is the only place that mints `llm_invoke_id`.
///
/// Two costs follow from reconstructing rather than observing, and neither can be designed
/// away here:
///
/// - These publish only after `send()` returns, so they arrive **after** the tool `node.*`
///   events from that same send. Timestamps interleave correctly; arrival order does not.
///   A consumer must sort by `stamp`.
/// - A round trip that failed and was retried inside Conduit leaves no message and no error,
///   so it is invisible. A terminal failure is reported, but as one event for the whole
///   `send()` rather than attributed to a particular trip.
enum RTSLLMEventEmission {

    /// Emits `llm.creation` / `llm.invocation` / `llm.response` per reconstructed round trip,
    /// plus a single `llm.failure` when the invocation ended in an error.
    ///
    /// - Parameters:
    ///   - messages: the session's messages for this invocation, already filtered by `runID`.
    ///   - llmID: identifies the *model*, not the round trip — see ``modelIdentifier(for:)``.
    ///   - nodeID: the enclosing agent invocation, which becomes every event's spatial parent.
    ///     This is the join key Python's visualizer uses to attribute an LLM call to a node.
    static func emit(
        into emitter: RTSEventEmitter,
        messages: [RTSMessage],
        llmID: String,
        modelProvider: String,
        modelName: String,
        nodeID: UUID,
        error: Error?
    ) async {
        // Checked here, not left to `emit`. Reconstruction awaits `RTSCostCalculator` per
        // assistant message, so the *arguments* to the events cost more than the events do —
        // and a flow built with `emitsEvents: false` is entitled to pay neither.
        guard emitter.isEnabled else {
            return
        }
        let spatialParent = RTSEventSpatialParent.node(nodeID: nodeID.uuidString)

        for roundTrip in await RTSLLMRoundTrip.reconstruct(from: messages) {
            // Fresh per trip: `llm_invoke_id` identifies one round trip, where `llm_id`
            // identifies the model across all of them.
            let parent = RTSEventParent.llm(
                llmTypeID: llmID,
                llmInvokeID: UUID().uuidString
            )
            // Python re-emits creation on every `invoke()` too; consumers deduplicate on
            // `(scope_id, llm_id)`.
            emitter.emit(
                RTSLLMCreationEvent(
                    llmID: llmID,
                    modelProvider: roundTrip.modelProvider ?? modelProvider,
                    modelName: roundTrip.modelName ?? modelName,
                    timestamp: roundTrip.requestedAt
                )
            )
            emitter.emit(
                RTSLLMInvocationEvent(
                    parent: parent,
                    spatialParent: spatialParent,
                    messageInput: roundTrip.messageInput,
                    timestamp: roundTrip.requestedAt
                )
            )
            emitter.emit(
                RTSLLMResponseEvent(
                    parent: parent,
                    spatialParent: spatialParent,
                    messageInput: roundTrip.messageInput,
                    output: roundTrip.output,
                    reportedModelName: roundTrip.modelName,
                    inputTokens: roundTrip.inputTokens,
                    outputTokens: roundTrip.outputTokens,
                    totalCost: roundTrip.totalCost,
                    systemFingerprint: roundTrip.systemFingerprint,
                    latency: roundTrip.latency,
                    timestamp: roundTrip.respondedAt
                )
            )
        }

        // An empty log means the session was never used, so whatever went wrong did not go
        // wrong in the model. An agent throws before `session.run` for its own reasons —
        // `RTSError.missingInput` when the prompt key is absent, for one — and reporting that
        // as an `llm.failure` would misattribute a node-level fault to the provider and
        // corrupt any error rate computed from this stream. Python cannot make this mistake:
        // its `LLMFailureEvent` comes only from inside the model call.
        //
        // Safe as a proxy because Conduit appends the user message *before* contacting the
        // provider, and `RTSLLMSession` publishes what accumulated when a send throws — so a
        // real model failure always leaves at least one message behind.
        guard let error, !messages.isEmpty else {
            return
        }
        // One failure for the whole send. The round trip that actually threw left no
        // assistant message, so it cannot be told apart from the ones that succeeded before
        // it; `message_input` is therefore everything accumulated when the error surfaced.
        emitter.emit(
            RTSLLMFailureEvent.from(
                error: error,
                parent: .llm(llmTypeID: llmID, llmInvokeID: UUID().uuidString),
                spatialParent: spatialParent,
                messageInput: messages
            )
        )
    }

    /// A stable `llm_id` for a provider + model pair.
    ///
    /// Python's is `ModelBase.id`, a uuid per model *object*, so two instances of one config
    /// get different ids — and a model *factory* yields a fresh id per call, meaning Python
    /// does not guarantee stability either. Deriving it from the configuration instead gives
    /// a consumer something stable to group by, which is what the field is for. Uses the same
    /// hash as the trace's `flow_id`.
    static func modelIdentifier(for provider: RTSLLMProvider) -> String {
        RailtracksSwift.equalityHash("\(provider.providerName).\(provider.modelID)")
    }
}
