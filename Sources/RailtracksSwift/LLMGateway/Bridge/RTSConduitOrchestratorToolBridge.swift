//
//  RTSConduitOrchestratorToolBridge.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-07-02.
//

import Foundation
import Conduit

/// Bridges an `RTSOrchestratorTool` to Conduit's `Tool` so a parent (OpenAI) agent's
/// LLM can invoke an orchestrator. Sibling of `RTSConduitAgentToolBridge`, but invokes
/// via `invokeFunction` + `RTSRunContext` instead of `invokeAgent` + a single session.
struct RTSConduitOrchestratorToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    private let orchestratorTool: RTSOrchestratorTool
    private let makeSession: @Sendable (any RTSAgentNode) throws -> RTSLLMSession
    private let onNewSession: @Sendable (RTSLLMSession) -> Void
    private let nodeInvoker: RTSNodeInvoker
    private let createdBy: any RTSAgentNode

    init(
        orchestratorTool: RTSOrchestratorTool,
        makeSession: @escaping @Sendable (any RTSAgentNode) throws -> RTSLLMSession,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void,
        nodeInvoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode
    ) {
        self.orchestratorTool = orchestratorTool
        self.makeSession = makeSession
        self.onNewSession = onNewSession
        self.nodeInvoker = nodeInvoker
        self.createdBy = createdBy
    }

    /// Sanitized: providers reject function names outside `[A-Za-z0-9_-]`. See `RTSProviderSafeName`.
    var name: String { RTSProviderSafeName.sanitized(orchestratorTool.name()) }
    var description: String { orchestratorTool.toolDescription }
    var parameters: GenerationSchema { orchestratorTool.parameterSchema.toGenerationSchema() }

    func call(arguments: GeneratedContent) async throws -> String {
        log.debug("🌁 RTSConduitOrchestratorToolBridge - \(orchestratorTool.name()) is called")
        log.trace("🌁 RTSConduitOrchestratorToolBridge - called with \(arguments.jsonString)")

        let jsonData = Data(arguments.jsonString.utf8)
        let toolArgs = try JSONDecoder().decode(RTSInput.self, from: jsonData)
        var input = orchestratorTool.wrappedOrchestrator.inputs
        input.merge(toolArgs) { _, new in new }
        if let transform = orchestratorTool.inputTransform {
            input = try await transform(input)
        }

        let context = RTSRunContext(
            invoker: nodeInvoker,
            makeSession: makeSession,
            onNewSession: onNewSession,
            createdBy: createdBy
        )
        var output = try await nodeInvoker.invokeFunction(
            orchestratorTool.wrappedOrchestrator,
            input: input,
            context: context,
            createdBy: createdBy
        )
        if let transform = orchestratorTool.outputTransform {
            output = try await transform(output)
        }

        guard let data = try? JSONEncoder().encode(output),
              let result = String(data: data, encoding: .utf8) else {
            throw RTSError.encodingFailed()
        }
        return result
    }
}
