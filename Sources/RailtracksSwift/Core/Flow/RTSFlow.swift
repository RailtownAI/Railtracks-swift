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
    let savesTrace: Bool
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
    ///   - savesTrace: When true (default), the run writes its JSON trace to
    ///     `flowGraphOutputDirectory`. Set false to run without persisting a trace (mirrors Python's
    ///     `rt.Flow(save_state=False)`) — used for internal sub-flows like the evaluation judge, whose
    ///     runs should not spill trace files. The completion lifecycle is unaffected.
    ///   - signpostEmitter: Emitter for Instruments signpost events. Defaults to a standard `RTSSignpostEmitter`.
    public init(
        title: String,
        savesTrace: Bool = true,
        signpostEmitter: (any RTSSignpostEmitting)? = nil
    ) {
        self.title = title
        self.savesTrace = savesTrace
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
    ///   - images: Optional images attached to the prompt for multimodal (vision) input. Requires a
    ///     vision-capable cloud model; ignored by on-device (AppleAI) agents.
    /// - Returns: The agent's text output.
    public func run(
        agent: some RTSAgentNode,
        prompt: String,
        gateway: RTSLLMGateway,
        systemMessage: String? = nil,
        images: [RTSImage] = []
    ) async throws -> String {
        let (nodeInvoker, collector, subscriptions) = await startCollecting()
        let onNewSession: @Sendable (RTSLLMSession) -> Void = { [collector] session in
            Task { await collector.subscribeMessage(session) }
        }

        let session = try gateway.session(
            invoker: nodeInvoker,
            agentNode: agent,
            onNewSession: onNewSession
        )
        onNewSession(session)   // subscribe the root agent's own session

        var input = agent.inputs
        input[agent.inputKeyPrompt] = .string(prompt)
        if let systemMessage {
            input[agent.inputKeySystemMessage] = .string(systemMessage)
        }
        if !images.isEmpty {
            input[agent.inputKeyImages] = .array(images.map { .image($0) })
        }

        let outcome: Result<String, Error>
        do {
            let output = try await nodeInvoker.invokeAgent(agent, input: input, session: session)
            guard case let .string(result) = output[agent.outputKeyResult] else {
                throw RTSError.missingOutput("Agent \(agent.agentName) missing result")
            }
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        await collector.awaitCompletion()
        _ = subscriptions       // keep alive until the run completes
        return try outcome.get()
    }

    /// Runs the pipeline from an orchestrating function node as the root. The node
    /// may invoke agents and other orchestrators through the provided `RTSRunContext`,
    /// all of which are traced as its children.
    ///
    /// - Returns: the function node's raw output.
    public func run(
        _ node: some RTSOrchestratorNode,
        input: RTSInput,
        gateway: RTSLLMGateway
    ) async throws -> RTSOutput {
        let (nodeInvoker, collector, subscriptions) = await startCollecting()
        let onNewSession: @Sendable (RTSLLMSession) -> Void = { [collector] session in
            Task { await collector.subscribeMessage(session) }
        }

        let context = RTSRunContext(
            invoker: nodeInvoker,
            makeSession: { agent in
                try gateway.session(
                    invoker: nodeInvoker,
                    agentNode: agent,
                    onNewSession: onNewSession
                )
            },
            onNewSession: onNewSession,
            createdBy: node
        )

        let outcome: Result<RTSOutput, Error>
        do {
            outcome = .success(try await nodeInvoker.invokeFunction(node, input: input, context: context))
        } catch {
            outcome = .failure(error)
        }
        await collector.awaitCompletion()
        _ = subscriptions       // keep alive until the run completes
        return try outcome.get()
    }

    /// Builds the per-run node invoker + graph collector and wires the
    /// `nodeStatusPublisher` subscriptions. The returned cancellables must be held
    /// for the duration of the run (they are kept alive by `run` awaiting completion).
    private func startCollecting() async -> (RTSNodeInvoker, RTSFlowGraphCollector, Set<AnyCancellable>) {
        // Warm the pricing map now (fire-and-forget) so the first per-node signpost cost
        // calculation doesn't pay the remote/disk fetch. It runs concurrently with the
        // flow and finishes long before the first node completes an LLM round-trip;
        // respects the TTL cache, so it's a cheap no-op on subsequent runs.
        Task { await RTSCostCalculator.shared.preloadPricing() }

        let stampFactory = RTSStampFactory()
        let nodeInvoker = RTSNodeInvoker(
            stampFactory: stampFactory,
            sessionID: id,
            signpostEmitter: signpostEmitter
        )

        var subscriptions = Set<AnyCancellable>()
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
            .store(in: &subscriptions)
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
            .store(in: &subscriptions)

        let collector = RTSFlowGraphCollector(
            stampFactory: stampFactory,
            flowName: title,
            sessionID: id,
            nodeEventPublisher: nodeInvoker,
            outputFileURLSubject: outputFileURLSubject,
            savesTrace: savesTrace,
            signpostEmitter: signpostEmitter
        )
        await collector.setup()
        return (nodeInvoker, collector, subscriptions)
    }

}
