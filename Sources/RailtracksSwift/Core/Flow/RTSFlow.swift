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
    private let outputFileURLSubject: CurrentValueSubject<Result<URL, Error>?, Never> = .init(nil)
    /// Publishes the outcome of the JSON trace write after each completed run.
    /// Emits `.success(url)` when the file is written, or `.failure(RTSError.writeFileFailed(path))`
    /// when encoding or writing fails, where the associated value is the attempted file path.
    /// Late subscribers receive the most recent result immediately.
    /// The initial `nil` state (no run completed yet) is filtered out.
    public var outputFileURLPublisher: AnyPublisher<Result<URL, Error>, Never> {
        outputFileURLSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    private let nodeStatusSubject = PassthroughSubject<RTSNodeStatus, Never>()
    /// Publishes a status event each time any node (agent or tool, including sub-agents) transitions state.
    /// Emits `.executing` when a node starts, `.completed` or `.failed` when it finishes.
    public var nodeStatusPublisher: AnyPublisher<RTSNodeStatus, Never> {
        nodeStatusSubject.eraseToAnyPublisher()
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

        // Storing subscription locally is sufficient.  It'll be kept alive,
        // because we wait for everything to complete before returning result in run
        var nodeStatusSubscriptions = Set<AnyCancellable>()
        nodeInvoker.nodeCreateEventPublisher
            .map {
                RTSNodeStatus(
                    nodeID: $0.id,
                    nodeName: $0.name,
                    nodeType: $0.nodeType,
                    state: .executing,
                    runID: $0.runID
                )
            }
            .sink { [weak self] in self?.nodeStatusSubject.send($0) }
            .store(in: &nodeStatusSubscriptions)
        nodeInvoker.nodeInvokeEventPublisher
            .map { event -> RTSNodeStatus in
                let state: RTSNodeStatus.State = event.error == nil
                    ? .completed
                    : .failed(event.error ?? "unknown")
                return RTSNodeStatus(
                    nodeID: event.id,
                    nodeName: event.name,
                    nodeType: event.nodeType,
                    state: state,
                    runID: event.runID
                )
            }
            .sink { [weak self] in self?.nodeStatusSubject.send($0) }
            .store(in: &nodeStatusSubscriptions)
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
