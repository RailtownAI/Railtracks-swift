//
//  RTSFlow.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation

/// Representation of Agent node in Railtracks pipeline
/// ```
/// RTFlow
///   │
///   ├── owns ──► RTSNodeInvoker
///   │                │
///   │                ├── publishes ──► RTSNodeEvent
///   │                │                      │
///   │                │              RTSFlowGraphCollector (actor)
///   │                │              subscribes & records
///   │                │
///   │                └── injected into
///   │                        │
///   │               ┌────────┴────────┐
///   │               │                 │
///   │           RTAgent          RTSConduitToolBridge
///   │               │                 │
///   │           invokes           invokes
///   │               │                 │
///   │        RTSLLMSession        RTSToolNode
///   │               │
///   │           messages()
///   │               │
///   │           RTSMessage[]
///   │           (contains tool_call_id
///   │            linking back to
///   │            RTSConduitToolBridge
///   │            invocation)
///   │
///   └── owns ──► RTSFlowGraphCollector
///                      │
///                      └── exportGraph() ──► RTSExecutionGraph (Codable)
///                                                   │
///                                                   └── writes ──► JSON file
/// ```
public class RTSFlow {
    let id: UUID = UUID()
    let title: String
    let entryPoint: (String) async -> String
    
    let stampFactory: RTSStampFactory
    let nodeInvoker: RTSNodeInvoker
    let flowGraphCollector: RTSFlowGraphCollector
    
    public init(title: String, entryPoint: @escaping (String) async -> String) {
        self.title = title
        self.entryPoint = entryPoint
        let stampFactory = RTSStampFactory()
        self.stampFactory = stampFactory
        self.nodeInvoker = RTSNodeInvoker(stampFactory: stampFactory)
        self.flowGraphCollector = RTSFlowGraphCollector(
            stampFactory: stampFactory,
            flowID: id,
            flowName: title
        )
    }
    
    public func session(gateway: RTSLLMGateway, tools: [any RTSToolNode] = []) -> RTSLLMSession {
        gateway.session(invoker: nodeInvoker, tools: tools)
    }
    
    func invoke(_ prompt: String) async -> String {
        return await self.entryPoint(prompt)
    }
}
