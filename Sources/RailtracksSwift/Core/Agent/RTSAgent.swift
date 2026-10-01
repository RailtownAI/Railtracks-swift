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
    /// Guardrails run, in order, on this agent's input before it reaches the LLM. Defaults to none.
    var inputGuardrails: [any RTSAgentInputGuardrail] { get }
    /// Guardrails run, in order, on this agent's output before it is returned. Defaults to none.
    var outputGuardrails: [any RTSAgentOutputGuardrail] { get }
}

/// The input keys an agent reads and how it turns them into its user message. Static so code
/// that has only the input, not the agent (e.g. the Instruments node summary in
/// `RTSSignpostEmitter`), derives the prompt exactly the way `invoke` does.
enum RTSAgentInput {
    static let systemMessageKey = "systemMessage"
    static let promptKey = "prompt"
    static let imagesKey = "images"

    /// The text the agent sends as its user message, or `nil` when the input has no string prompt.
    static func prompt(in inputs: RTSInput) -> String? {
        guard case let .string(prompt) = inputs[promptKey] else {
            return nil
        }
        return prompt
    }

    /// The images the agent attaches to its user message; non-image entries are skipped.
    static func images(in inputs: RTSInput) -> [RTSImage] {
        guard case let .array(values) = inputs[imagesKey] else {
            return []
        }
        return values.compactMap { value in
            guard case let .image(image) = value else {
                return nil
            }
            return image
        }
    }
}

public extension RTSAgentNode {
    var inputKeySystemMessage: String {
        RTSAgentInput.systemMessageKey
    }
    var inputKeyPrompt: String {
        RTSAgentInput.promptKey
    }
    var inputKeyImages: String {
        RTSAgentInput.imagesKey
    }
    var outputKeyResult: String {
        "result"
    }

    var agentName: String {
        String(describing: type(of: self))
    }
    var outputSchemaMaxToken: Int {
        4096
    }
    var inputGuardrails: [any RTSAgentInputGuardrail] { [] }
    var outputGuardrails: [any RTSAgentOutputGuardrail] { [] }

    func name() -> String {
        agentName
    }

    func invoke() async throws -> RTSOutput { [:] }

    func invoke(runID: RTSRunID, session: RTSLLMSession) async throws -> RTSOutput {
        guard let prompt = RTSAgentInput.prompt(in: inputs) else {
            throw RTSError.missingInput("Agent \(agentName) missing prompt")
        }
        if case let .string(systemMessage) = inputs[inputKeySystemMessage] {
            session.setSystemPrompt(systemMessage, runID: runID)
        }
        let images = RTSAgentInput.images(in: inputs)
        do {
            let result = try await session.run(prompt, images: images, runID: runID)
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
    public let inputGuardrails: [any RTSAgentInputGuardrail]
    public let outputGuardrails: [any RTSAgentOutputGuardrail]
    public var inputs: RTSInput = [:]

    public init(
        llmProvider: RTSLLMProvider,
        name: String? = nil,
        tools: [any RTSToolNode] = [],
        systemMessage: String? = nil,
        outputSchema: RTSOutputSchema? = nil,
        outputSchemaMaxToken: Int = 4096,
        inputGuardrails: [any RTSAgentInputGuardrail] = [],
        outputGuardrails: [any RTSAgentOutputGuardrail] = []
    ) {
        self.agentName = name ?? "Agent"
        self.tools = tools
        self.llmProvider = llmProvider
        self.outputSchema = outputSchema
        self.outputSchemaMaxToken = outputSchemaMaxToken
        self.inputGuardrails = inputGuardrails
        self.outputGuardrails = outputGuardrails
        if let systemMessage {
            inputs[inputKeySystemMessage] = .string(systemMessage)
        }
    }
}
