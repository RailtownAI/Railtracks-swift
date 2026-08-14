//
//  RTSLLMGateway.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-28.
//

import Foundation
import Conduit

/// Encapsulation layer for against the LLM connection service underneath
/// If the llm model accessing library underneath is replaced, only files under LLMGateway directory should require update while the rest  can remain the same
public struct RTSLLMGateway: Sendable {
    private let apiKeys: [RTSLLMProviderKind: String]

    /// - Parameter apiKeys: API keys keyed by provider. Only keys for providers used by
    ///   the agents in a given flow are required (e.g. `[.openAI: "sk-..."]`).
    public init(apiKeys: [RTSLLMProviderKind: String]) {
        self.apiKeys = apiKeys
    }

    func session(
        invoker: RTSNodeInvoker,
        agentNode: any RTSAgentNode,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void
    ) throws -> RTSLLMSession {
        try Self.buildSession(apiKeys: apiKeys, invoker: invoker, agentNode: agentNode, onNewSession: onNewSession)
    }

    private static func buildSession(
        apiKeys: [RTSLLMProviderKind: String],
        invoker: RTSNodeInvoker,
        agentNode: any RTSAgentNode,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void
    ) throws -> RTSLLMSession {
        let provider = agentNode.llmProvider
        // The provider-agnostic seam every agent passes through, `RTSAgent` and custom
        // `RTSAgentNode` conformers alike — so the collision check lives here rather than in any one
        // agent's initializer, where a conformer that builds its own tool list would never run it.
        //
        // TODO: dedupe the logging. This runs once per *session build*, i.e. once per agent
        // invocation, so the same line repeats: once per run for the root agent, and — the unbounded
        // case — once per call for a sub-agent, since `RTSAgentTool` builds its session lazily at call
        // time. A sub-agent the model calls 20 times logs its rewrites 20 times. Keying on
        // `agentName` + the tool-name set would collapse it, at the cost of shared mutable state here
        // (a lock or an actor). Only affects release builds: in DEBUG `assertNoCollisions` traps on
        // the first collision, and a rewrite alone is informational.
        let authoredToolNames = agentNode.tools.map(\.toolName)
        RTSProviderSafeName.logRewrites(of: authoredToolNames, agentName: agentNode.agentName)
        RTSProviderSafeName.assertNoCollisions(among: authoredToolNames, agentName: agentNode.agentName)
        switch provider {
        case .appleAI:
            guard #available(macOS 26, iOS 26, *) else {
                throw RTSError.providerUnavailable(
                    "AppleAI (FoundationModels) requires macOS 26 / iOS 26 or later"
                )
            }
            let (appleAISession, unsupported) = try AppleAISession.build(
                fromAgentTools: agentNode.tools,
                invoker: invoker,
                createdBy: agentNode,
                makeSubSession: { subAgent in
                    try RTSLLMGateway.buildSession(
                        apiKeys: apiKeys,
                        invoker: invoker,
                        agentNode: subAgent,
                        onNewSession: onNewSession
                    )
                },
                onNewSession: onNewSession
            )
            if !unsupported.isEmpty {
                log.warning("⚠️ [\(agentNode.agentName)] \(unsupported.count) tool(s) ignored — conform to RTSAppleAIToolNode to use tools with AppleAI: [\(unsupported.map(\.toolName))]")
            }
            return RTSLLMSession.build(appleAI: appleAISession, agentNode: agentNode)

        case .openAI(modelIDString: let modelIDString):
            guard let apiKey = apiKeys[provider.kind] else {
                throw RTSError.missingAPIKey("No API key provided for \(provider.providerName)")
            }
            return try buildCloudSession(
                provider: OpenAIProvider(apiKey: apiKey),
                model: .openAI(modelIDString),
                apiKeys: apiKeys,
                invoker: invoker,
                agentNode: agentNode,
                onNewSession: onNewSession,
                // No provider-specific settings on this path. Passed explicitly rather than defaulted
                // so a new provider case cannot silently skip forwarding its own.
                applyProviderOptions: { _ in }
            )

        case .anthropic(modelIDString: let modelIDString):
            guard let apiKey = apiKeys[provider.kind] else {
                throw RTSError.missingAPIKey("No API key provided for \(provider.providerName)")
            }
            return try buildCloudSession(
                provider: AnthropicProvider(apiKey: apiKey),
                model: .anthropic(modelIDString),
                apiKeys: apiKeys,
                invoker: invoker,
                agentNode: agentNode,
                onNewSession: onNewSession,
                // No provider-specific settings on this path. Passed explicitly rather than defaulted
                // so a new provider case cannot silently skip forwarding its own.
                applyProviderOptions: { _ in }
            )

        case .gemini(modelIDString: let modelIDString, options: let options):
            guard let apiKey = apiKeys[provider.kind] else {
                throw RTSError.missingAPIKey("No API key provided for \(provider.providerName)")
            }
            return try buildCloudSession(
                provider: GeminiProvider(apiKey: apiKey),
                model: .gemini(modelIDString),
                apiKeys: apiKeys,
                invoker: invoker,
                agentNode: agentNode,
                onNewSession: onNewSession,
                applyProviderOptions: options.applyToConduitConfig
            )
        }
    }

    /// Builds a session for a cloud (Conduit-backed) provider. The tool-bridging is provider-agnostic,
    /// so OpenAI, Anthropic, and Gemini share this — only the provider instance + model identifier differ.
    private static func buildCloudSession<Provider: AIProvider & TextGenerator>(
        provider: Provider,
        model: ModelIdentifier,
        apiKeys: [RTSLLMProviderKind: String],
        invoker: RTSNodeInvoker,
        agentNode: any RTSAgentNode,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void,
        applyProviderOptions: @escaping @Sendable (inout GenerateConfig) -> Void
    ) throws -> RTSLLMSession where Provider.ModelID == ModelIdentifier {
        let conduitTools: [any Tool] = agentNode.tools.map { tool in
            if let agentTool = tool as? RTSAgentTool {
                let makeSession: @Sendable () throws -> RTSLLMSession = {
                    try RTSLLMGateway.buildSession(
                        apiKeys: apiKeys,
                        invoker: invoker,
                        agentNode: agentTool.wrappedAgent,
                        onNewSession: onNewSession
                    )
                }
                return RTSConduitAgentToolBridge(
                    agentTool: agentTool,
                    makeSession: makeSession,
                    onNewSession: onNewSession,
                    nodeInvoker: invoker,
                    createdBy: agentNode
                )
            } else if let orchestratorTool = tool as? RTSOrchestratorTool {
                let makeSession: @Sendable (any RTSAgentNode) throws -> RTSLLMSession = { subAgent in
                    try RTSLLMGateway.buildSession(
                        apiKeys: apiKeys,
                        invoker: invoker,
                        agentNode: subAgent,
                        onNewSession: onNewSession
                    )
                }
                return RTSConduitOrchestratorToolBridge(
                    orchestratorTool: orchestratorTool,
                    makeSession: makeSession,
                    onNewSession: onNewSession,
                    nodeInvoker: invoker,
                    createdBy: agentNode
                )
            } else {
                return tool.asConduitTool(invoker: invoker, createdBy: agentNode)
            }
        }
        return try RTSLLMSession.build(
            provider: provider,
            model: model,
            agentNode: agentNode,
            conduitTools: conduitTools,
            applyProviderOptions: applyProviderOptions
        )
    }
}

extension Model: @retroactive CustomStringConvertible {
    public var description: String {
        return "\(family.description)-\(id)"
    }
}

extension Model.Family: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .mlx:
            return "mlx"
        case .mlxLocal:
            return "mlxLocal"
        case .llama:
            return "llama"
        case .coreML:
            return "coreML"
        case .foundationModels:
            return "foundationModels"
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "anthropic"
        case .huggingFace:
            return "huggingFace"
        case .kimi:
            return "kimi"
        case .miniMax:
            return "miniMax"
        case .custom:
            return "Custom"
        case .gemini:
            return "gemini"
        }
    }
}
