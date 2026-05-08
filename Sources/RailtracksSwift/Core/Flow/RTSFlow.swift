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
public class RTFlow {
    let id: UUID = UUID()
    let title: String
    let entryPoint: (String) async -> String
    
    let stampFactory: RTSStampFactory
    let nodeInvoker: RTSNodeInvoker
    let flowGraphCollector: RTSFlowGraphCollector
    
    init(title: String, entryPoint: @escaping (String) async -> String) {
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
    
    func invoke(_ prompt: String) async -> String {
        return await self.entryPoint(prompt)
    }
}
