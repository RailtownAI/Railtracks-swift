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
}

/// An operator that facilitate with node invoking, and publish node invoke event
/// All node invoking should go through this, otherwise will have even record inconsistency
public class RTSNodeInvoker: @unchecked Sendable {
    let stampFactory: RTSStampFactory
    
    let nodeCreateEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    let nodeInvokeEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    
    init(stampFactory: RTSStampFactory) {
        self.stampFactory = stampFactory
    }
    
    func invoke(_ node: some RTSNode, input: RTSInput, createdBy: String? = nil) async throws -> RTSOutput {
        let creationEvent: RTSStamp.Event
        if let createdBy {
            creationEvent = .create(createdBy, node.name())
        } else {
            creationEvent = .startCreate(node.name())
        }
        let startStamp = await stampFactory.makeStamp(event: creationEvent)
        nodeCreateEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                stamp: startStamp
            )
        )
        
        let runID = UUID()
        var mutableNode = node
        mutableNode.inputs = input

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

        let finishStamp = await stampFactory.makeStamp(event: .finishExecution(node.name()))
        nodeInvokeEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                stamp: finishStamp,
                input: input,
                output: invokeError == nil ? output : nil,
                error: invokeError.map { "\($0)" },
                runID: runID
            )
        )
        if let invokeError { throw invokeError }
        return output
    }
}

extension RTSNodeInvoker: NodeEventPublishers {
    var nodeCreateEventPublisher: AnyPublisher<RTSNodeEvent, Never> {
        nodeCreateEventSubject.eraseToAnyPublisher()
    }
    var nodeInvokeEventPublisher: AnyPublisher<RTSNodeEvent, Never> {
        nodeInvokeEventSubject.eraseToAnyPublisher()
    }
}
