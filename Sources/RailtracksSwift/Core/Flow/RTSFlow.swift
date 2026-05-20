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
        
        var mutableAgent = agent
        var subSessions: [RTSLLMSession] = []
        mutableAgent.tools = wireAgentTools(
            mutableAgent.tools,
            parent: mutableAgent,
            invoker: nodeInvoker,
            gateway: gateway,
            subSessions: &subSessions
        )
        let session = gateway.session(invoker: nodeInvoker, agentNode: mutableAgent)
        flowGraphCollector.subscribeMessage(session)
        subSessions.forEach { flowGraphCollector.subscribeMessage($0) }

        var input = mutableAgent.inputs
        input[mutableAgent.inputKeyPrompt] = .string(prompt)
        if let systemMessage {
            input[mutableAgent.inputKeySystemMessage] = .string(systemMessage)
        }

        let output = try await nodeInvoker.invoke(mutableAgent, input: input, session: session)
        guard case let .string(result) = output[mutableAgent.outputKeyResult] else {
            throw RTSError.missingOutput("Agent \(mutableAgent.agentName) missing result")
        }
        await flowGraphCollector.awaitCompletion()
        return result
    }
    
    /// Recursion wiring so all the sub-agents being tools are wired up properly with sub-sessions
    private func wireAgentTools(
        _ tools: [any RTSToolNode],
        parent: any RTSAgentNode,
        invoker: RTSNodeInvoker,
        gateway: RTSLLMGateway,
        subSessions: inout [RTSLLMSession]
    ) -> [any RTSToolNode] {
        tools.map { tool -> any RTSToolNode in
            guard var agentTool = tool as? RTSAgentTool else { return tool }
            agentTool.wrappedAgent.tools = wireAgentTools(
                agentTool.wrappedAgent.tools,
                parent: agentTool.wrappedAgent,
                invoker: invoker,
                gateway: gateway,
                subSessions: &subSessions
            )
            let subSession = gateway.session(invoker: invoker, agentNode: agentTool.wrappedAgent)
            subSessions.append(subSession)
            agentTool.callableRoutine = RTSClosure { [wrapped = agentTool.wrappedAgent, parent = parent] inputs in
                try await invoker.invoke(wrapped, input: inputs, session: subSession, createdBy: parent)
            }
            return agentTool
        }
    }
}
