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
    let stampFactory: RTSStampFactory
    let sessionID: UUID
    let signpostEmitter: (any RTSSignpostEmitting)?

    let nodeCreateEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    let nodeInvokeEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    let edgeCreateEventSubject = PassthroughSubject<RTSEdgeEvent, Never>()
    let edgeFinishEventSubject = PassthroughSubject<RTSEdgeEvent, Never>()

    init(
        stampFactory: RTSStampFactory,
        sessionID: UUID,
        signpostEmitter: (any RTSSignpostEmitting)? = nil
    ) {
        self.stampFactory = stampFactory
        self.sessionID = sessionID
        self.signpostEmitter = signpostEmitter
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
        return try await invokeCore(
            node,
            nodeType: .agent,
            provider: node.llmProvider.providerName,
            model: node.llmProvider.modelID,
            input: input,
            createdBy: createdBy,
            runInputGuardrails: inputGuardrails.isEmpty ? nil : { input in
                await RTSGuardrailRunner.runInput(inputGuardrails, input: input)
            },
            runOutputGuardrails: outputGuardrails.isEmpty ? nil : { output in
                await RTSGuardrailRunner.runOutput(outputGuardrails, output: output)
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

    private func invokeCore(
        _ node: some RTSNode,
        nodeType: RTSFlowNodeType,
        provider: String,
        model: String,
        input: RTSInput,
        createdBy: (any RTSNode)? = nil,
        runInputGuardrails: ((RTSInput) async -> (value: RTSInput, traces: [RTSGuardrailTrace], error: Error?))? = nil,
        runOutputGuardrails: ((RTSOutput) async -> (value: RTSOutput, traces: [RTSGuardrailTrace], error: Error?))? = nil,
        execute: (UUID, RTSInput) async throws -> RTSOutput
    ) async throws -> RTSOutput {
        let event: RTSStamp.Event
        if let sourceName = createdBy?.name() {
            event = .create(sourceName, node.name())
        } else {
            event = .startCreate(node.name())
        }
        let creationStamp = await stampFactory.makeStamp(event: event)
        await publishNodeCreated(
            node,
            nodeType: nodeType,
            provider: provider,
            model: model,
            stamp: creationStamp,
            createdBy: createdBy
        )

        // Input guardrails run before the edge is recorded so the edge's input
        // reflects what the agent actually received (post-transform).
        var guardTraces: [RTSGuardrailTrace] = []
        var workingInput = input
        var guardError: Error?
        if let runInputGuardrails {
            let result = await runInputGuardrails(input)
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
            from: createdBy,
            to: node,
            input: workingInput
        )

        signpostEmitter?.emitNodeStart(
            nodeID: node.id,
            nodeName: node.name(),
            nodeType: nodeType,
            sessionID: sessionID,
            parentName: createdBy?.name() ?? "",
            runID: runID,
            input: workingInput
        )

        var output: RTSOutput = [:]
        // A blocked/errored input guardrail short-circuits: the LLM never runs.
        var invokeError: Error? = guardError
        if invokeError == nil {
            do {
                output = try await execute(runID, workingInput)
            } catch {
                invokeError = error
                output = [:]
            }
            // Output guardrails only run when the agent itself produced a result.
            if invokeError == nil, let runOutputGuardrails {
                let result = await runOutputGuardrails(output)
                output = result.value
                guardTraces.append(contentsOf: result.traces)
                invokeError = result.error
            }
        }

        signpostEmitter?.emitNodeEnd(
            nodeID: node.id,
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
            from: createdBy,
            to: node,
            input: workingInput,
            output: output,
            error: invokeError
        )
        await publishNodeFinished(
            node,
            nodeType: nodeType,
            stamp: completionStamp,
            runID: runID,
            input: workingInput,
            output: output,
            error: invokeError,
            guardTraces: guardTraces
        )

        if let invokeError { throw invokeError }
        return output
    }

    private func publishNodeCreated(
        _ node: some RTSNode,
        nodeType: RTSFlowNodeType,
        provider: String,
        model: String,
        stamp: RTSStamp,
        createdBy: (any RTSNode)?
    ) async {
        nodeCreateEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                nodeType: nodeType,
                stamp: stamp,
                provider: provider,
                model: model
            )
        )
    }

    private func publishNodeFinished(
        _ node: some RTSNode,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        runID: UUID,
        input: RTSInput,
        output: RTSOutput,
        error: Error?,
        guardTraces: [RTSGuardrailTrace] = []
    ) async {
        nodeInvokeEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                nodeType: nodeType,
                stamp: stamp,
                input: input,
                output: error == nil ? output : nil,
                error: error.map { "\($0)" },
                runID: runID,
                guardTraces: guardTraces
            )
        )
    }

    private func publishEdgeCreated(
        edgeID: UUID,
        runID: UUID,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        from source: (any RTSNode)?,
        to target: some RTSNode,
        input: RTSInput
    ) async {
        edgeCreateEventSubject.send(
            RTSEdgeEvent(
                id: edgeID,
                runID: runID,
                stamp: stamp,
                nodeType: nodeType,
                sourceNodeID: source?.id,
                targetNodeID: target.id,
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
        from source: (any RTSNode)?,
        to target: some RTSNode,
        input: RTSInput,
        output: RTSOutput,
        error: Error?
    ) async {
        edgeFinishEventSubject.send(
            RTSEdgeEvent(
                id: edgeID,
                runID: nil,
                stamp: stamp,
                nodeType: nodeType,
                sourceNodeID: source?.id,
                targetNodeID: target.id,
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
