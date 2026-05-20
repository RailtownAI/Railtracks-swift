//
//  RTSNode.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-01.
//

import Foundation

/// RTSNode protocol describes Node objects that have collected all its input and waiting to be executed via invoke
public protocol RTSNode: Sendable {
    var id: UUID { get }
    var inputs: RTSInput { get set }
    
    func name() -> String
    /// execution function to be run by invoker operator
    func invoke() async throws -> RTSOutput
}

public protocol RTSFunctionNode: RTSNode {
    var callableRoutine: RTSClosure { get }
}

public extension RTSFunctionNode {
    func invoke() async throws -> RTSOutput {
        return try await callableRoutine.closure(inputs)
    }
}

/// wrapper around closure to conform to encodable
public struct RTSClosure: Encodable, @unchecked Sendable {
    let closure: @concurrent (RTSInput) async throws -> RTSOutput
    
    public init(closure: @escaping @Sendable (RTSInput) async throws -> RTSOutput) {
        self.closure = closure
    }
    
    public func encode(to encoder: Encoder) throws { } // intentionally empty
}
