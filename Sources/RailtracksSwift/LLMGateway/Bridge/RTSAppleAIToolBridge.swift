//
//  RTSAppleAIToolBridge.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-28.
//

import Foundation
import FoundationModels

/// Wraps an `RTSAppleAIToolNode` and routes `call(arguments:)` through `RTSNodeInvoker`,
/// so AppleAI tool invocations appear in the flow graph trace exactly like Conduit tool calls.
///
/// Must be generic (unlike `RTSConduitToolBridge`) because FoundationModels derives the
/// argument schema from the concrete `Arguments` type at compile time.
struct RTSAppleAIToolBridge<WrappedTool: RTSAppleAIToolNode>: Tool
    where WrappedTool.Arguments: Encodable & Generable, WrappedTool.Output == String {

    typealias Arguments = WrappedTool.Arguments
    typealias Output = String

    let wrappedTool: WrappedTool
    let nodeInvoker: RTSNodeInvoker
    let createdBy: any RTSAgentNode

    var name: String { wrappedTool.name }
    var description: String { wrappedTool.description }

    func call(arguments: WrappedTool.Arguments) async throws -> String {
        let data = try JSONEncoder().encode(arguments)
        let input = try JSONDecoder().decode(RTSInput.self, from: data)
        let output = try await nodeInvoker.invokeTool(wrappedTool, input: input, createdBy: createdBy)
        let outputData = try JSONEncoder().encode(output)
        return String(data: outputData, encoding: .utf8) ?? "{}"
    }
}

public extension RTSAppleAIToolNode where Arguments: Encodable & Generable, Output == String {
    func makeAppleAIBridge(invoker: RTSNodeInvoker, createdBy: any RTSAgentNode) -> (any Tool)? {
        RTSAppleAIToolBridge(wrappedTool: self, nodeInvoker: invoker, createdBy: createdBy)
    }
}
