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
    var toolName: String { get }
    var inputs: RTSInput { get set }
    var callableRoutine: RTSClosure { get }
    
    var toolDescription: String { get }
    var parameterSchema: RTSToolSchema { get }
}
                
public extension RTSToolNode {
    public var toolName: String {
        String(describing: type(of: self))
    }
    public func name() -> String { toolName }
    public func invoke() async throws -> RTSOutput { try await callableRoutine.closure(inputs) }
    public func run(with inputs: RTSInput) async throws -> RTSOutput {
        var copy = self
        copy.inputs = inputs
        return try await copy.invoke()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RTSToolNodeCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .name)
        try container.encode(inputs, forKey: .inputs)
    }
}
