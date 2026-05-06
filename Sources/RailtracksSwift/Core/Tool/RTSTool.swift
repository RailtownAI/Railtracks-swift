//
//  RTSTool.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-30.
//

import Foundation

enum RTSToolNodeCodingKeys: String, CodingKey {
    case id, name, inputs
}

public protocol RTSToolNode: RTSFunctionNode {
    typealias RTSInput = [String: RTSValue]
    
    var id: UUID { get }
    var _name: String { get }
    var inputs: RTSInput { get set }
    var callableRoutine: RTSClosure { get }
    
    var toolDescription: String { get }
    var parameterSchema: RTSToolSchema { get }
}
                
public extension RTSToolNode {
    public func name() -> String { _name }
    public func invoke() async throws -> RTSOutput { try await callableRoutine.closure(inputs) }
    public func run(with inputs: RTSInput) async throws -> RTSOutput {
        var copy = self
        copy.inputs = inputs
        return try await copy.invoke()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RTSToolNodeCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(_name, forKey: .name)
        try container.encode(inputs, forKey: .inputs)
    }
}
