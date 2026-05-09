//
//  RTSNodeInvoker.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation
import Combine

/// An operator that facilitate with node invoking, and publish node invoke event
/// All node invoking should go through this, otherwise will have even record inconsistency
public class RTSNodeInvoker: @unchecked Sendable {
    let stampFactory: RTSStampFactory
    
    let nodeCreateEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    var nodeCreateEventPublisher: AnyPublisher<RTSNodeEvent, Never> {
        nodeCreateEventSubject.eraseToAnyPublisher()
    }
    let nodeInvokeEventSubject = PassthroughSubject<RTSNodeEvent, Never>()
    var nodeInvokeEventPublisher: AnyPublisher<RTSNodeEvent, Never> {
        nodeInvokeEventSubject.eraseToAnyPublisher()
    }
    
    init(stampFactory: RTSStampFactory) {
        self.stampFactory = stampFactory
    }
    
    func invoke(_ node: some RTSNode, input: RTSInput) async throws -> RTSOutput {
        let startStamp = await stampFactory.makeStamp(event: .startCreate(node.name()))
        nodeCreateEventSubject.send(
            RTSNodeEvent(
                nodeID: node.id,
                name: node.name(),
                stamp: startStamp
            )
        )
        
        let output = try await node.invoke()
        
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
