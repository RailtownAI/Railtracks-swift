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
    var id: UUID { get }
    var toolName: String { get }
    var inputs: RTSInput { get set }
    var callableRoutine: RTSClosure { get }

    var toolDescription: String { get }
    var parameterSchema: RTSToolSchema { get }
    /// When `true`, a failure to register this tool with the LLM provider
    /// (e.g. schema conversion failure) throws an error instead of silently dropping the tool.
    var isRequired: Bool { get }

    func invoke(runID: RTSRunID) async throws -> RTSOutput
}
                
public extension RTSToolNode {
    var toolName: String {
        String(describing: type(of: self))
    }
    var isRequired: Bool { false }
    
    func name() -> String { toolName }
    func invoke() async throws -> RTSOutput {
        try await callableRoutine.closure(inputs)
    }
    func invoke(runID: RTSRunID) async throws -> RTSOutput {
        try await invoke()
    }
    func run(with inputs: RTSInput) async throws -> RTSOutput {
        var copy = self
        copy.inputs = inputs
        return try await copy.invoke()
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RTSToolNodeCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolName, forKey: .name)
        try container.encode(inputs, forKey: .inputs)
    }
}
