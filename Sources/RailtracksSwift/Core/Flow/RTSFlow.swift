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
    
    public init(
        title: String
    ) {
        self.title = title
    }

    public func run(
        agent: some RTSAgentNode,
        prompt: String,
        gateway: RTSLLMGateway,
        systemMessage: String? = nil
    ) async throws -> String {
        let stampFactory = RTSStampFactory()
        let nodeInvoker = RTSNodeInvoker(stampFactory: stampFactory)
        let flowGraphCollector = RTSFlowGraphCollector(
            stampFactory: stampFactory,
            flowName: title,
            nodeEventPublisher: nodeInvoker
        )
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
        await flowGraphCollector.awaitCompletion()
        return result
    }
}
