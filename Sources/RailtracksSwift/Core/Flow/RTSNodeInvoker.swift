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
        mutableNode.inputs = input
        return try await invokeCore(
            node,
            nodeType: .agent,
            input: input,
            createdBy: createdBy
        ) { runID in
            try await mutableNode.invoke(runID: runID, session: session)
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
            input: input,
            createdBy: createdBy
        ) { runID in
            try await mutableNode.invoke(runID: runID)
        }
    }

    private func invokeCore(
        _ node: some RTSNode,
        nodeType: RTSFlowNodeType,
        input: RTSInput,
        createdBy: (any RTSNode)? = nil,
        execute: (UUID) async throws -> RTSOutput
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
            stamp: creationStamp,
            createdBy: createdBy
        )

        let runID = UUID()
        let edgeID = runID
        await publishEdgeCreated(
            edgeID: edgeID,
            nodeType: nodeType,
            stamp: creationStamp,
            from: createdBy,
            to: node,
            input: input
        )

        signpostEmitter?.emitNodeStart(
            nodeID: node.id,
            nodeName: node.name(),
            nodeType: nodeType,
            sessionID: sessionID,
            parentName: createdBy?.name() ?? "",
            runID: runID,
            input: input
        )

        let output: RTSOutput
        var invokeError: Error?
        do {
            output = try await execute(runID)
        } catch {
            invokeError = error
            output = [:]
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
            input: input,
            output: output,
            error: invokeError
        )
        await publishNodeFinished(
            node,
            nodeType: nodeType,
            stamp: completionStamp,
            runID: runID,
            input: input,
            output: output,
            error: invokeError
        )

        if let invokeError { throw invokeError }
        return output
    }

    private func publishNodeCreated(
        _ node: some RTSNode,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        createdBy: (any RTSNode)?
    ) async {
        nodeCreateEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                nodeType: nodeType,
                stamp: stamp
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
        error: Error?
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
                runID: runID
            )
        )
    }

    private func publishEdgeCreated(
        edgeID: UUID,
        nodeType: RTSFlowNodeType,
        stamp: RTSStamp,
        from source: (any RTSNode)?,
        to target: some RTSNode,
        input: RTSInput
    ) async {
        edgeCreateEventSubject.send(
            RTSEdgeEvent(
                id: edgeID,
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
