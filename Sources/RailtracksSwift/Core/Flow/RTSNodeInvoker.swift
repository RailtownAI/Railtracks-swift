//
//  RTSNodeInvoker.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation
import Combine

protocol NodeEventPublishers {
    var nodeCreateEventPublisher: AnyPublisher<RTSNodeEvent, Never> { get }
    var nodeInvokeEventPublisher: AnyPublisher<RTSNodeEvent, Never> { get }
    var edgeCreateEventPublisher: AnyPublisher<RTSEdgeEvent, Never> { get }
    var edgeFinishEventPublisher: AnyPublisher<RTSEdgeEvent, Never> { get }
}

/// An operator that facilitate with node invoking, and publish node invoke event
/// All node invoking should go through this, otherwise will have even record inconsistency
public class RTSNodeInvoker: @unchecked Sendable {
    typealias InvocationID = UUID
    typealias RunInputGuardrail = (RTSInput, InvocationID) async -> RTSGuardrailInputOutcome
    typealias RunOutputGuardrail = (RTSOutput, InvocationID) async -> RTSGuardrailOutputOutcome
    /// Called once the node body has finished, with the ids minted inside `invokeCore` and
    /// the error if it threw. Only agents supply one — it is where `llm.*` is reconstructed
    /// from the session's messages, which `invokeCore` cannot reach.
    typealias EmitLLMEvents = (InvocationID, UUID, Error?) async -> Void
    
    let stampFactory: RTSStampFactory
    let sessionID: UUID
    let signpostEmitter: (any RTSSignpostEmitting)?

    let nodeCreateEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    let nodeInvokeEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    let edgeCreateEventSubject = PassthroughSubject<RTSEdgeEvent, Never>()
    let edgeFinishEventSubject = PassthroughSubject<RTSEdgeEvent, Never>()

    /// Fires when a node's body is about to run — after input guardrails, immediately before
    /// `execute`. Its only consumer today is `RTSFlow`, which turns it into the executing state of
    /// `RTSNodeStatus` so a UI can show a node waiting on a slow guardrail.
    let nodeExecutionEventSubject = PassthroughSubject<RTSNodeExecutionEvent, Never>()

    /// Serializes the event `send(...)` calls below. One `RTSNodeInvoker` is shared by every
    /// agent/tool in a flow, and `PassthroughSubject.send` is NOT safe under concurrent calls — so a
    /// flow that runs agents in parallel would otherwise data-race on event publication. This backs the
    /// `@unchecked Sendable` conformance with real synchronization.
    private let publishLock = NSLock()

    /// The invocation id of the node currently executing on this task. A child invocation reads it
    /// as its parent (the edge `source`). It is bound around `execute` so it flows down the async
    /// call tree — including Conduit's tool `TaskGroup` and Apple's `LanguageModelSession.respond`,
    /// both verified to inherit task-locals. `nil` at the flow root. See docs/duplicate-node-id.md.
    @TaskLocal static var currentInvocationID: InvocationID?

    /// Publishes the structured observability event stream. Optional so tests can build an
    /// invoker without one; `nil` means node and guardrail events are simply not emitted.
    let eventEmitter: RTSEventEmitter?

    init(
        stampFactory: RTSStampFactory,
        sessionID: UUID,
        signpostEmitter: (any RTSSignpostEmitting)? = nil,
        eventEmitter: RTSEventEmitter? = nil
    ) {
        self.stampFactory = stampFactory
        self.sessionID = sessionID
        self.signpostEmitter = signpostEmitter
        self.eventEmitter = eventEmitter
    }
    
    func invokeAgent(
        _ node: any RTSAgentNode,
        input: RTSInput,
        session: RTSLLMSession,
        createdBy: (any RTSNode)? = nil
    ) async throws -> RTSOutput {
        var mutableNode = node
        let inputGuardrails = node.inputGuardrails
        let outputGuardrails = node.outputGuardrails
        // Scopes each rail's middleware type id to the agent that owns it.
        let agentName = node.agentName
        let provider = node.llmProvider
        return try await invokeCore(
            node,
            nodeType: .agent,
            provider: node.llmProvider.providerName,
            model: node.llmProvider.modelID,
            input: input,
            createdBy: createdBy,
            runInputGuardrails: inputGuardrails.isEmpty ? nil : { [eventEmitter] input, nodeID in
                await RTSGuardrailRunner.runInput(
                    inputGuardrails,
                    input: input,
                    eventContext: RTSGuardrailEventContext(
                        emitter: eventEmitter,
                        nodeID: nodeID,
                        agentName: agentName
                    )
                )
            },
            runOutputGuardrails: outputGuardrails.isEmpty ? nil : { [eventEmitter] output, nodeID in
                await RTSGuardrailRunner.runOutput(
                    outputGuardrails,
                    output: output,
                    eventContext: RTSGuardrailEventContext(
                        emitter: eventEmitter,
                        nodeID: nodeID,
                        agentName: agentName
                    )
                )
            },
            emitLLMEvents: { [eventEmitter] nodeID, runID, error in
                guard let eventEmitter else {
                    return
                }
                await RTSLLMEventEmission.emit(
                    into: eventEmitter,
                    // The session accumulates across invocations, so filter to this one.
                    messages: session.messages().filter { $0.runID == runID },
                    llmID: RTSLLMEventEmission.modelIdentifier(for: provider),
                    modelProvider: provider.providerName,
                    modelName: provider.modelID,
                    nodeID: nodeID,
                    error: error
                )
            }
        ) { runID, guardedInput in
            mutableNode.inputs = guardedInput
            return try await mutableNode.invoke(runID: runID, session: session)
        }
    }

    func invokeTool(
        _ node: some RTSToolNode,
        input: RTSInput,
        createdBy: (any RTSNode)? = nil
    ) async throws -> RTSOutput {
        var mutableNode = node
        mutableNode.inputs = input
        return try await invokeCore(
            node,
            nodeType: .tool,
            provider: "",
            model: "",
            input: input,
            createdBy: createdBy
        ) { runID, _ in
            try await mutableNode.invoke(runID: runID)
        }
    }

    /// Invokes an orchestrator (function) node. `createdBy: nil` makes it the flow
    /// root; passing a parent draws an edge from that parent. The node runs with an
    /// `RTSRunContext` so it can invoke agents / other orchestrators as its children.
    func invokeFunction(
        _ node: any RTSOrchestratorNode,
        input: RTSInput,
        context: RTSRunContext,
        createdBy: (any RTSNode)? = nil
    ) async throws -> RTSOutput {
        var mutableNode = node
        return try await invokeCore(
            node,
            nodeType: .function,
            provider: "",
            model: "",
            input: input,
            createdBy: createdBy
        ) { _, guardedInput in
            mutableNode.inputs = guardedInput
            return try await mutableNode.run(guardedInput, context: context)
        }
    }

    private func invokeCore(
        _ node: some RTSNode,
        nodeType: RTSFlowNodeType,
        provider: String,
        model: String,
        input: RTSInput,
        createdBy: (any RTSNode)? = nil,
        // The `UUID` is the node's per-invocation id, which only exists inside this function —
        // the guardrail runner needs it as the spatial parent of its `middleware.guard.*` events.
        runInputGuardrails: RunInputGuardrail? = nil,
        runOutputGuardrails: RunOutputGuardrail? = nil,
        emitLLMEvents: EmitLLMEvents? = nil,
        execute: (UUID, RTSInput) async throws -> RTSOutput
    ) async throws -> RTSOutput {
        let event: RTSStamp.Event
        if let sourceName = createdBy?.name() {
            event = .create(sourceName, node.name())
        } else {
            event = .startCreate(node.name())
        }
        let creationStamp = await stampFactory.makeStamp(event: event)

        // Per-invocation graph node id (matches Python): a node invoked N times yields N distinct
        // ids. The node *instance* id (`node.id`) is no longer used for tracing identity.
        let invocationID = InvocationID()
        // The parent invocation's id, propagated down the task tree; nil at the flow root.
        let parentInvocationID = RTSNodeInvoker.currentInvocationID
        #if DEBUG
        if createdBy != nil, parentInvocationID == nil {
            log.error("🧵 invocation-id propagation lost for \(node.name()) — its edge will be orphaned; check for Task.detached on the invoke path")
        }
        #endif

        await publishNodeCreated(
            node,
            nodeID: invocationID,
            parentNodeID: parentInvocationID,
            nodeType: nodeType,
            provider: provider,
            model: model,
            stamp: creationStamp,
            createdBy: createdBy,
            hasInputGuardrail: runInputGuardrails != nil,
            hasOutputGuardrail: runOutputGuardrails != nil
        )

        // Observability stream (independent of the trace above). `node.creation` is a
        // creation event: it precedes the node entering its own scope, so it carries no
        // parent — matching Python's `CreationEventBase`.
        let eventParent = RTSEventParent.node(nodeID: invocationID.uuidString)
        let eventSpatialParent = RTSEventSpatialParent.node(nodeID: parentInvocationID?.uuidString)
        eventEmitter?.emit(
            RTSNodeCreationEvent(
                nodeID: invocationID.uuidString,
                name: node.name(),
                nodeType: nodeType
            )
        )
        // Emitted *before* the guardrails, so a blocked input guardrail still leaves the node
        // with a complete lifecycle rather than a creation and a destruction with nothing
        // between them. It also puts `kwargs` at the pre-transform value, which is what
        // Python records — its input guards are model middleware and never see the node's
        // kwargs. (The flow-graph edge below deliberately records post-transform instead; the
        // two streams differ here on purpose.)
        eventEmitter?.emit(
            RTSNodeInvocationEvent(
                parent: eventParent,
                spatialParent: eventSpatialParent,
                kwargs: input
            )
        )

        // Input guardrails run before the edge is recorded so the edge's input
        // reflects what the agent actually received (post-transform).
        var guardTraces: [RTSGuardrailTrace] = []
        var workingInput = input
        var guardError: Error?
        if let runInputGuardrails {
            let result = await runInputGuardrails(input, invocationID)
            workingInput = result.value
            guardTraces.append(contentsOf: result.traces)
            guardError = result.error
        }

        let runID = UUID()
        let edgeID = createdBy == nil ? runID : UUID()
        await publishEdgeCreated(
            edgeID: edgeID,
            runID: runID,
            nodeType: nodeType,
            stamp: creationStamp,
            sourceNodeID: parentInvocationID,
            targetNodeID: invocationID,
            from: createdBy,
            to: node,
            input: workingInput
        )

        signpostEmitter?.emitNodeStart(
            nodeID: invocationID,
            nodeName: node.name(),
            nodeType: nodeType,
            sessionID: sessionID,
            parentName: createdBy?.name() ?? "",
            runID: runID,
            input: workingInput,
            hasInputGuardrail: runInputGuardrails != nil,
            hasOutputGuardrail: runOutputGuardrails != nil
        )

        // Guardrails are done and the body is about to run: the point where a UI flips this node from
        // queued to executing. Published even when a guardrail already failed above, so a node never
        // finishes without having been seen to start.
        await publishNodeExecuting(
            node,
            nodeID: invocationID,
            parentNodeID: parentInvocationID,
            nodeType: nodeType,
            runID: runID
        )

        var output: RTSOutput = [:]
        // A blocked/errored input guardrail short-circuits: the LLM never runs.
        var invokeError: Error? = guardError
        var runtime: TimeInterval = 0
        if invokeError == nil {
            // Measure the node's actual execution with a monotonic clock, at the source — mirrors
            // Python's `tracked_invoke`. The parser reads this instead of subtracting create/finish
            // stamps, which is exact and avoids stamp-pairing ambiguity.
            let started = DispatchTime.now()
            do {
                // Bind this node's invocation id for the dynamic extent of `execute`, so any child
                // node invoked within it reads this as its parent (edge source) via the task-local.
                output = try await RTSNodeInvoker.$currentInvocationID.withValue(invocationID) {
                    try await execute(runID, workingInput)
                }
            } catch {
                invokeError = error
                output = [:]
                log.error("☠️ [\(node.name())] invocation failed: \(error)")
            }
            runtime = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
            // `llm.*` is reconstructed from the messages the body left behind — see
            // `RTSLLMEventEmission`. Placed here so it lands inside the node's own lifecycle,
            // as Python's does: after the body, before the output guardrails and before the
            // terminal node event. Runs on failure too, since a partial exchange still
            // produced messages worth reporting. Deliberately outside the measured window, so
            // reconstruction never inflates the node's reported runtime.
            await emitLLMEvents?(invocationID, runID, invokeError)
            // Output guardrails only run when the agent itself produced a result. They run after the
            // measured window (not counted as node runtime), matching Python measuring only invoke().
            if invokeError == nil, let runOutputGuardrails {
                let result = await runOutputGuardrails(output, invocationID)
                output = result.value
                guardTraces.append(contentsOf: result.traces)
                invokeError = result.error
            }
        }

        // The node's single terminal event. Both arms live here, outside the block above,
        // because `invokeError` is only final at this point:
        //
        // - A node can fail three ways — an input guardrail blocking or throwing (set before
        //   `execute` even runs), the body throwing, or an output guardrail blocking or
        //   throwing — and only the middle one passes through the `catch` above. Emitting here
        //   covers all three, matching Python, which reports a blocked guard as a
        //   `node.failure` because the block raises through the node body.
        // - `node.response` cannot be emitted next to `execute`, because an output guardrail
        //   can fail *after* the body succeeded. Doing so emitted both a response and a
        //   failure for one invocation. Emitting it here also means `output` has already been
        //   through the output guardrails, so a redacting rail's result is what reaches the
        //   stream rather than the raw value.
        //
        // Note `.transformed` and `.allowed` never reach the failure arm: the guardrail runner
        // returns a nil error for both.
        if let invokeError {
            eventEmitter?.emit(
                RTSNodeFailureEvent.from(
                    error: invokeError,
                    parent: eventParent,
                    spatialParent: eventSpatialParent
                )
            )
        } else {
            eventEmitter?.emit(
                RTSNodeResponseEvent(
                    parent: eventParent,
                    spatialParent: eventSpatialParent,
                    response: .object(output)
                )
            )
        }

        signpostEmitter?.emitNodeEnd(
            nodeID: invocationID,
            nodeName: node.name(),
            nodeType: nodeType,
            sessionID: sessionID,
            parentName: createdBy?.name() ?? "",
            runID: runID,
            output: invokeError == nil ? output : nil,
            error: invokeError
        )

        let completionStamp = await stampFactory.makeStamp(event: .finishExecution(node.name()))
        await publishEdgeFinished(
            edgeID: edgeID,
            nodeType: nodeType,
            stamp: completionStamp,
            sourceNodeID: parentInvocationID,
            targetNodeID: invocationID,
            from: createdBy,
            to: node,
            input: workingInput,
            output: output,
            error: invokeError
        )
        await publishNodeFinished(
            node,
            nodeID: invocationID,
            parentNodeID: parentInvocationID,
            nodeType: nodeType,
            stamp: completionStamp,
            runID: runID,
            input: workingInput,
            output: output,
            error: invokeError,
            runtime: runtime,
            guardTraces: guardTraces,
            hasInputGuardrail: runInputGuardrails != nil,
            hasOutputGuardrail: runOutputGuardrails != nil
        )

        // The final response, and the event Python's `node_internals` fold reads for latency.
        // `runtime` is the monotonic measurement taken above, never a stamp delta.
        eventEmitter?.emit(
            RTSNodeDestructionEvent(
                parent: eventParent,
                spatialParent: eventSpatialParent,
                response: invokeError == nil ? .object(output) : nil,
                durationSeconds: runtime
            )
        )

        if let invokeError { throw invokeError }
        return output
    }

    /// Serialized `send` — the invoker is shared across a flow's agents and `PassthroughSubject.send`
    /// isn't concurrency-safe, so parallel agents would otherwise race on event publication. This is
    /// synchronous (no suspension), so locking here is safe and legal from the async publish methods.
    private func lockedSend<Event>(_ subject: PassthroughSubject<Event, Never>, _ event: Event) {
        publishLock.lock()
        defer { publishLock.unlock() }
        subject.send(event)
    }

    private func publishNodeCreated(
        _ node: some RTSNode,
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeType: RTSFlowNodeType,
        provider: String,
        model: String,
        stamp: RTSStamp,
        createdBy: (any RTSNode)?,
        hasInputGuardrail: Bool = false,
        hasOutputGuardrail: Bool = false
    ) async {
        lockedSend(
            nodeCreateEventSubject,
            RTSNodeEvent(
                nodeID: nodeID,
                parentNodeID: parentNodeID,
                name: node.name(),
                nodeType: nodeType,
                stamp: stamp,
                provider: provider,
                model: model,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            )
        )
    }

    /// Announces that a node's body is starting, after input guardrails have run — the queued →
    /// executing transition in `RTSNodeStatus`. Takes no stamp: `RTSStampFactory` hands out the
    /// monotonic indices the trace orders by, and this event has no need to consume one.
    private func publishNodeExecuting(
        _ node: some RTSNode,
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeType: RTSFlowNodeType,
        runID: UUID
    ) async {
        lockedSend(
            nodeExecutionEventSubject,
            RTSNodeExecutionEvent(
                nodeID: nodeID,
                parentNodeID: parentNodeID,
                name: node.name(),
                nodeType: nodeType,
                runID: runID
            )
        )
    }

    private func publishNodeFinished(
        _ node: some RTSNode,
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        runID: UUID,
        input: RTSInput,
        output: RTSOutput,
        error: Error?,
        runtime: TimeInterval? = nil,
        guardTraces: [RTSGuardrailTrace] = [],
        hasInputGuardrail: Bool = false,
        hasOutputGuardrail: Bool = false
    ) async {
        lockedSend(
            nodeInvokeEventSubject,
            RTSNodeEvent(
                nodeID: nodeID,
                parentNodeID: parentNodeID,
                name: node.name(),
                nodeType: nodeType,
                stamp: stamp,
                input: input,
                output: error == nil ? output : nil,
                error: error.map { "\($0)" },
                runID: runID,
                runtime: runtime,
                guardTraces: guardTraces,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            )
        )
    }

    private func publishEdgeCreated(
        edgeID: UUID,
        runID: UUID,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        sourceNodeID: UUID?,
        targetNodeID: UUID,
        from source: (any RTSNode)?,
        to target: some RTSNode,
        input: RTSInput
    ) async {
        lockedSend(
            edgeCreateEventSubject,
            RTSEdgeEvent(
                id: edgeID,
                runID: runID,
                stamp: stamp,
                nodeType: nodeType,
                sourceNodeID: sourceNodeID,
                targetNodeID: targetNodeID,
                sourceName: source?.name(),
                targetName: target.name(),
                input: input
            )
        )
    }

    private func publishEdgeFinished(
        edgeID: UUID,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        sourceNodeID: UUID?,
        targetNodeID: UUID,
        from source: (any RTSNode)?,
        to target: some RTSNode,
        input: RTSInput,
        output: RTSOutput,
        error: Error?
    ) async {
        lockedSend(
            edgeFinishEventSubject,
            RTSEdgeEvent(
                id: edgeID,
                runID: nil,
                stamp: stamp,
                nodeType: nodeType,
                sourceNodeID: sourceNodeID,
                targetNodeID: targetNodeID,
                sourceName: source?.name(),
                targetName: target.name(),
                input: input,
                output: error == nil ? output : nil,
                error: error.map { "\($0)" }
            )
        )
    }
}

extension RTSNodeInvoker: NodeEventPublishers {
    var nodeCreateEventPublisher: AnyPublisher<RTSNodeEvent, Never> {
        nodeCreateEventSubject.eraseToAnyPublisher()
    }
    var nodeInvokeEventPublisher: AnyPublisher<RTSNodeEvent, Never> {
        nodeInvokeEventSubject.eraseToAnyPublisher()
    }
    var edgeCreateEventPublisher: AnyPublisher<RTSEdgeEvent, Never> {
        edgeCreateEventSubject.eraseToAnyPublisher()
    }
    var edgeFinishEventPublisher: AnyPublisher<RTSEdgeEvent, Never> {
        edgeFinishEventSubject.eraseToAnyPublisher()
    }
}

extension RTSNodeInvoker {
    /// Deliberately **not** part of `NodeEventPublishers` — yet.
    ///
    /// That protocol is the trace collector's view of the invoker (`RTSFlowGraphCollector` takes it
    /// and nothing else). The collector has no use for this event today, and putting it on the
    /// protocol would force every conformer to implement an unused member. Should the trace ever want
    /// a recorded execution-start — splitting guardrail latency from execution latency — moving it
    /// onto the protocol is additive and needs no rename. `RTSFlow` holds the concrete
    /// `RTSNodeInvoker`, so it reads this directly in the meantime.
    var nodeExecutionEventPublisher: AnyPublisher<RTSNodeExecutionEvent, Never> {
        nodeExecutionEventSubject.eraseToAnyPublisher()
    }
}
