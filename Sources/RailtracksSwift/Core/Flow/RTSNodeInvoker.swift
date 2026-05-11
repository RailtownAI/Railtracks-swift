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
    
    func invoke(_ node: some RTSNode, input: RTSInput) async throws -> RTSOutput {
        let startStamp = await stampFactory.makeStamp(event: .startCreate(node.name()))
        // TODO: double check if creation event here is good enough, or need to be more realistic, and have invoker be the sole entity to create nodes and trigger event there
        nodeCreateEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                stamp: startStamp
            )
        )
        
        var mutableNode = node
        mutableNode.inputs = input
        let output = try await mutableNode.invoke()
        
        let finishStamp = await stampFactory.makeStamp(event: .finishExecution(node.name()))
        nodeInvokeEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                stamp: finishStamp,
                output: output
            )
        )
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
