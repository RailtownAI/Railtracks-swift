//
//  RTSFlow.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation

/// Representation of Agent node in Railtracks pipeline
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
            flowName: title,
            nodeEventPublisher: self.nodeInvoker
        )
    }
    
    func invoke(_ prompt: String) async -> String {
        return await self.entryPoint(prompt)
    }

    public func run(
        agent: some RTSAgentNode,
        prompt: String,
        gateway: RTSLLMGateway,
        systemMessage: String? = nil
    ) async throws -> String {
        await flowGraphCollector.setup()
        
        let session = gateway.session(invoker: nodeInvoker, agentNode: agent)
        flowGraphCollector.subscribeMessage(session)

        var input = agent.inputs
        input[agent.inputKeyPrompt] = .string(prompt)
        if let systemMessage {
            input[agent.inputKeySystemMessage] = .string(systemMessage)
        }

        let output = try await nodeInvoker.invoke(agent, input: input, session: session)
        guard case let .string(result) = output[agent.outputKeyResult] else {
            throw RTSError.missingOutput("Agent \(agent.agentName) missing result")
        }
        return result
    }
}
