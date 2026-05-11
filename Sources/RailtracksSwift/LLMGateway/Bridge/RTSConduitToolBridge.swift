//
//  RTSConduitToolBridge.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-05.
//

import Foundation
import ConduitAdvanced

struct RTSConduitToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    
    internal let node: any RTSToolNode
    internal let nodeInvoker: RTSNodeInvoker
    
    var name: String { node.name() }
    var description: String { node.toolDescription }
    var parameters: GenerationSchema { node.parameterSchema.toGenerationSchema() }
    
    func call(arguments: GeneratedContent) async throws -> String {
        log.debug("🌁 RTSConduitToolBridge - \(node.name()) is called with \(arguments.jsonString)")
        let jsonData = Data(arguments.jsonString.utf8)
        let input = try JSONDecoder().decode(RTSInput.self, from: jsonData)
//        let output = try await node.run(with: input)
        let output = try await nodeInvoker.invoke(node, input: input)
        guard let data = try? JSONEncoder().encode(output),
              let result = String(data: data, encoding: .utf8) else {
            throw RTSError.encodingFailed()
        }
        return result
    }
}

public extension RTSToolNode {
    func asConduitTool(invoker: RTSNodeInvoker) -> any Tool {
        RTSConduitToolBridge(node: self, nodeInvoker: invoker)
    }
}
