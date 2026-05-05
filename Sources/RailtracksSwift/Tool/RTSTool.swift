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
//    var callableClosure: @concurrent (RTSInput) async throws -> RTSOutput { get }
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

///// Default simple tool struct
//public struct RTSTool {
//    public typealias RTSInput = [String: RTSValue]
//    
//    let id = UUID()
//    let _name: String
//    // TODO: review manifest logic in py that Agent can use
//    
//    public var inputs: RTSInput
//    public let callableRoutine: @concurrent (RTSInput) async throws -> RTSOutput
//    
//    public init(
//        name: String,
//        inputs: RTSInput? = nil,
//        callableRoutine: @escaping (RTSInput) async throws -> RTSOutput
//    ) {
//        self._name = name
//        self.inputs = inputs ?? [:]
//        self.callableRoutine = callableRoutine
//    }
//    
//    // direct execution input
//    public func run(with inputs: RTSInput) -> RTSTool {
//        var copy = self
//        copy.inputs = inputs
//        return copy
//    }
//}
//
//extension RTSTool: RTSFunctionNode {
//    public func name() -> String {
//        return _name
//    }
//}
//    
//extension RTSTool: Encodable {
//    enum CodingKeys: String, CodingKey {
//        case id
//        case name
//        case inputs
//    }
//    
//    public func encode(to encoder: Encoder) throws {
//        var container = encoder.container(keyedBy: CodingKeys.self)
//        try container.encode(id, forKey: .id)
//        try container.encode(_name, forKey: .name)
//        try container.encode(inputs, forKey: .inputs)
//    }
//}
