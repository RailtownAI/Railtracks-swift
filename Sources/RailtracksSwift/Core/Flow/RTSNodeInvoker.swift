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
    
    let nodeCreateEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    let nodeInvokeEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    let edgeCreateEventSubject = PassthroughSubject<RTSEdgeEvent, Never>()
    let edgeFinishEventSubject = PassthroughSubject<RTSEdgeEvent, Never>()
    
    init(stampFactory: RTSStampFactory) {
        self.stampFactory = stampFactory
    }
    
    func invoke(
        _ node: some RTSNode,
        input: RTSInput,
        createdBy: (any RTSNode)? = nil
    ) async throws -> RTSOutput {
        await publishNodeCreated(node, createdBy: createdBy)

        let runID = UUID()
        var mutableNode = node
        mutableNode.inputs = input

        let edgeID = createdBy == nil ? runID : UUID()
        await publishEdgeCreated(edgeID: edgeID, from: createdBy, to: node, input: input)

        // execution
        let output: RTSOutput
        var invokeError: Error?
        do {
            if let agentNode = mutableNode as? any RTSAgentNode {
                output = try await agentNode.invoke(runID: runID)
            } else {
                output = try await mutableNode.invoke()
            }
        } catch {
            invokeError = error
            output = [:]
        }

        await publishEdgeFinished(
            edgeID: edgeID,
            from: createdBy,
            to: node,
            input: input,
            output: output,
            error: invokeError
        )
        await publishNodeFinished(
            node,
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
        createdBy: (any RTSNode)?
    ) async {
        let event: RTSStamp.Event
        if let sourceName = createdBy?.name() {
            event = .create(sourceName, node.name())
        } else {
            event = .startCreate(node.name())
        }
        let stamp = await stampFactory.makeStamp(event: event)
        nodeCreateEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                stamp: stamp
            )
        )
    }

    private func publishNodeFinished(
        _ node: some RTSNode,
        runID: UUID,
        input: RTSInput,
        output: RTSOutput,
        error: Error?
    ) async {
        let stamp = await stampFactory.makeStamp(event: .finishExecution(node.name()))
        nodeInvokeEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
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
        from source: (any RTSNode)?,
        to target: some RTSNode,
        input: RTSInput
    ) async {
        let event: RTSStamp.Event
        if let sourceName = source?.name() {
            event = .create(sourceName, target.name())
        } else {
            event = .startCreate(target.name())
        }
        let stamp = await stampFactory.makeStamp(event: event)
        edgeCreateEventSubject.send(
            RTSEdgeEvent(
                id: edgeID,
                stamp: stamp,
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
        from source: (any RTSNode)?,
        to target: some RTSNode,
        input: RTSInput,
        output: RTSOutput,
        error: Error?
    ) async {
        let stamp = await stampFactory.makeStamp(event: .finishExecution(target.name()))
        edgeFinishEventSubject.send(
            RTSEdgeEvent(
                id: edgeID,
                stamp: stamp,
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
