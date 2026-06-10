//
//  RTSAgent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-24.
//

import Foundation
import Logging

public protocol RTSAgentNode: RTSNode {
    var id: UUID { get }
    var agentName: String { get }
    var tools: [any RTSToolNode] { get }
    var llmProvider: RTSLLMProvider { get }
    var outputSchema: RTSOutputSchema? { get }
    /// Maximum tokens the LLM may use when generating structured output against `outputSchema`.
    /// Defaults to `4096`. Ignored when `outputSchema` is `nil`.
    var outputSchemaMaxToken: Int { get }
}

public extension RTSAgentNode {
    public var inputKeySystemMessage: String { "systemMessage" }
    public var inputKeyPrompt: String { "prompt" }
    public var outputKeyResult: String { "result" }

    var agentName: String {
        String(describing: type(of: self))
    }
    var outputSchemaMaxToken: Int { 4096 }

    func name() -> String { agentName }

    func invoke() async throws -> RTSOutput { [:] }

    func invoke(runID: UUID, session: RTSLLMSession) async throws -> RTSOutput {
        guard case let .string(prompt) = inputs[inputKeyPrompt] else {
            throw RTSError.missingInput("Agent \(agentName) missing prompt")
        }
        if case let .string(systemMessage) = inputs[inputKeySystemMessage] {
            session.setSystemPrompt(systemMessage, runID: runID)
        }
        do {
            let result = try await session.run(prompt, runID: runID)
            return [outputKeyResult: .string(result)]
        } catch {
            log.debug("agent(\(id)) failed at running prompt: \(prompt) | \(error)")
            throw error
        }
    }
}

public struct RTSAgent: RTSAgentNode {
    public let id: UUID = UUID()
    public let agentName: String
    public let tools: [any RTSToolNode]
    public let llmProvider: RTSLLMProvider
    public let outputSchema: RTSOutputSchema?
    public let outputSchemaMaxToken: Int
    public var inputs: RTSInput = [:]

    public init(
        llmProvider: RTSLLMProvider,
        name: String? = nil,
        tools: [any RTSToolNode] = [],
        systemMessage: String? = nil,
        outputSchema: RTSOutputSchema? = nil,
        outputSchemaMaxToken: Int = 4096
    ) {
        self.agentName = name ?? "Agent"
        self.tools = tools
        self.llmProvider = llmProvider
        self.outputSchema = outputSchema
        self.outputSchemaMaxToken = outputSchemaMaxToken
        if let systemMessage {
            inputs[inputKeySystemMessage] = .string(systemMessage)
        }
    }
}
