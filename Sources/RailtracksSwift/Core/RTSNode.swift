//
//  RTSNode.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-01.
//

import Foundation

/// RTSNode protocol describes Node objects that have collected all its input and waiting ot be executed via invoke
public protocol RTSNode: Encodable {
    typealias RTSOutput = [String: RTSValue]
    func name() -> String
    func invoke() async throws -> RTSOutput
}

// TODO: reassess the need to have RTSAgentNode and RTSFunctionNode as protocol over concrete class
public protocol RTSAgentNode: RTSNode {
    
}

public protocol RTSFunctionNode: RTSNode {
    typealias RTSInput = [String: RTSValue]
    
    var inputs: RTSInput { get }
    var callableRoutine: @concurrent (RTSInput) async throws -> RTSOutput { get }
}

public extension RTSFunctionNode {
    public func invoke() async throws -> RTSOutput {
        return try await callableRoutine(inputs)
    }
}
