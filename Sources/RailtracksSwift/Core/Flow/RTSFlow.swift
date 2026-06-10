//
//  RTSFlow.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation
import Combine

/// Representation of Agent node in Railtracks pipeline
public class RTSFlow: @unchecked Sendable {
    let id: UUID = UUID()
    let title: String
    let signpostEmitter: any RTSSignpostEmitting
    private let outputFileURLSubject: CurrentValueSubject<URL?, Never> = .init(nil)
    /// Publishes the file URL of the JSON trace written after each completed run.
    /// Emits once per `run(...)` call after the flow graph file has been written to
    /// `RailtracksSwift.flowGraphOutputDirectory`. The initial `nil` state is filtered out.
    public var outputFileURLPublisher: AnyPublisher<URL, Never> {
        outputFileURLSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    /// - Parameters:
    ///   - title: Display name for the flow, included in the trace file name.
    ///   - signpostEmitter: Emitter for Instruments signpost events. Defaults to a standard `RTSSignpostEmitter`.
    public init(
        title: String,
        signpostEmitter: (any RTSSignpostEmitting)? = nil
    ) {
        self.title = title
        self.signpostEmitter = signpostEmitter ?? RTSSignpostEmitter()
    }

    /// Runs the pipeline from the given root agent and returns its text result.
    ///
    /// Creates a fresh node invoker and graph collector, wires up event subscriptions,
    /// invokes the agent, then waits for the JSON trace file to finish writing before returning.
    ///
    /// - Parameters:
    ///   - agent: Root agent node to invoke.
    ///   - prompt: User prompt passed to the agent.
    ///   - gateway: Gateway used to build LLM sessions for the agent and any sub-agents.
    ///   - systemMessage: Optional system message applied to the agent's session before the prompt is sent.
    /// - Returns: The agent's text output.
    public func run(
        agent: some RTSAgentNode,
        prompt: String,
        gateway: RTSLLMGateway,
        systemMessage: String? = nil
    ) async throws -> String {
        let stampFactory = RTSStampFactory()
        let nodeInvoker = RTSNodeInvoker(
            stampFactory: stampFactory,
            sessionID: id,
            signpostEmitter: signpostEmitter
        )
        let flowGraphCollector = RTSFlowGraphCollector(
            stampFactory: stampFactory,
            flowName: title,
            sessionID: id,
            nodeEventPublisher: nodeInvoker,
            outputFileURLSubject: outputFileURLSubject,
            signpostEmitter: signpostEmitter
        )
        await flowGraphCollector.setup()
        
        let session = try gateway.session(
            invoker: nodeInvoker,
            agentNode: agent
        ) { [flowGraphCollector] newSession in
            // subscription for descendant agents
            Task { await flowGraphCollector.subscribeMessage(newSession) }
        }
        // subscription for root agent
        Task { await flowGraphCollector.subscribeMessage(session) }

        var input = agent.inputs
        input[agent.inputKeyPrompt] = .string(prompt)
        if let systemMessage {
            input[agent.inputKeySystemMessage] = .string(systemMessage)
        }

        let output = try await nodeInvoker.invokeAgent(agent, input: input, session: session)
        guard case let .string(result) = output[agent.outputKeyResult] else {
            throw RTSError.missingOutput("Agent \(agent.agentName) missing result")
        }
        await flowGraphCollector.awaitCompletion()
        return result
    }
    
}
