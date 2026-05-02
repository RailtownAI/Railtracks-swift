//
//  RTSTool.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-30.
//

import Foundation

///// RTSNode protocol describes Node objects that have collected all its input and waiting ot be executed
//protocol RTSNode: Codable {
//    associatedtype Output: Codable
//    
//    /// Human readible identifcation for the node
//    func name() -> String
//    
//    /// Trigger to ask the node to execute it's pre-determined task
//    func invoke() async throws -> Output
//}

//protocol RTSAgentNode: RTSNode {
//    
//}
//
//protocol RTSFunctionNode: RTSNode {
////    associatedtype Input: Codable
////    var runClosure: ((repeat each Input)) -> [Output] { get }
//}

//protocol RTSTool {
//    var callableRoutine: CallableClosure { get }
//    var name: String { get }
//    //TODO: manifest
//}

/// Default simple tool struct
struct RTSTool {
//struct RTSTool<Output: Codable, each Input: Codable> {
//    typealias Inputs = (repeat each T)
//    typealias Output = RTSSerializableDictionary
    typealias RTSInput = [String: RTSValue]
    
    let id = UUID()
    let _name: String
    // TODO: review manifest logic in py that Agent can use
    
    let inputs: RTSInput
//    let callableRoutine: RTSCallableClosure
//    let callableRoutine: ((repeat each Input) -> Output)
    let callableRoutine: (RTSInput) async throws -> RTSOutput
    
//    var inputs: (repeat each Input)
    
//    func run( ) async throws -> RTSSerializableDictionary {
//        
//    }
    
//    var inputDictionary: RTSSerializableDictionary
}

/// Coding keys for RTSTool struct
///
/// enum is moved outside of RTSTool because swift compiler current cannot distinguish the fact that inputs in enum case is not actually a type of type parameter packs (variadic generics)
//enum RTSToolCodingKeys: String, CodingKey {
//    case id
//    case _name
//    case inputs = "routineInputs"
//}

extension RTSTool: RTSFunctionNode {
//    typealias Output = RTSSerializableDictionary
    
//    var runClosure: ((repeat each Input)) -> [Output] {
//        return callableRoutine
//    }
    
    func name() -> String {
        return _name
    }
}
    
extension RTSTool: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inputs
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(_name, forKey: .name)
        try container.encode(inputs, forKey: .inputs)
    }
}
