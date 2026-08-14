//
//  RTSAppleAIOrchestratorToolBridge.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-07-02.
//

import Foundation
import FoundationModels

/// Bridges an `RTSOrchestratorTool` to FoundationModels' `Tool` so a parent (AppleAI)
/// agent can invoke an orchestrator. Sibling of `RTSAppleAIAgentToolBridge`, but invokes
/// via `invokeFunction` + `RTSRunContext` instead of `invokeAgent`.
@available(macOS 26, iOS 26, *)
struct RTSAppleAIOrchestratorToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let orchestratorTool: RTSOrchestratorTool
    private let makeSession: @Sendable (any RTSAgentNode) throws -> RTSLLMSession
    private let onNewSession: @Sendable (RTSLLMSession) -> Void
    private let nodeInvoker: RTSNodeInvoker
    private let createdBy: any RTSAgentNode

    init(
        orchestratorTool: RTSOrchestratorTool,
        parameters: GenerationSchema,
        makeSession: @escaping @Sendable (any RTSAgentNode) throws -> RTSLLMSession,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void,
        nodeInvoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode
    ) {
        self.name = RTSProviderSafeName.sanitized(orchestratorTool.name())
        self.description = orchestratorTool.toolDescription
        self.parameters = parameters
        self.orchestratorTool = orchestratorTool
        self.makeSession = makeSession
        self.onNewSession = onNewSession
        self.nodeInvoker = nodeInvoker
        self.createdBy = createdBy
    }

    func call(arguments: GeneratedContent) async throws -> String {
        log.debug("🍎 RTSAppleAIOrchestratorToolBridge - \(orchestratorTool.name()) is called")

        var input = orchestratorTool.wrappedOrchestrator.inputs
        for param in orchestratorTool.parameters.parameters {
            switch param.type {
            case .string:
                if let value = try? arguments.value(String.self, forProperty: param.name) {
                    input[param.name] = .string(value)
                }
            case .number:
                if let value = try? arguments.value(Double.self, forProperty: param.name) {
                    input[param.name] = .number(value)
                }
            case .bool:
                if let value = try? arguments.value(Bool.self, forProperty: param.name) {
                    input[param.name] = .bool(value)
                }
            case .array(let elementType):
                switch elementType {
                case .string:
                    if let value = try? arguments.value([String].self, forProperty: param.name) {
                        input[param.name] = .array(value.map { .string($0) })
                    }
                case .number:
                    if let value = try? arguments.value([Double].self, forProperty: param.name) {
                        input[param.name] = .array(value.map { .number($0) })
                    }
                case .bool:
                    if let value = try? arguments.value([Bool].self, forProperty: param.name) {
                        input[param.name] = .array(value.map { .bool($0) })
                    }
                case .array:
                    log.warning("⚠️ 🍎 '\(orchestratorTool.name())' parameter '\(param.name)' uses nested arrays which are not supported — value dropped")
                }
            }
        }
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
