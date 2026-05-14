//
//  RTSAgent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-24.
//

import Foundation
import Logging

public protocol RTSAgentNode: RTSNode {
    // TODO: reassess the need to have RTSAgentNode and RTSFunctionNode as protocol over concrete class
    var id: UUID { get }
    var agentName: String { get }
    var tools: [any RTSToolNode] { get }
    var llmProvider: RTSLLMProvider { get }
}

public extension RTSAgentNode {
    var inputKeySystemMessage: String { "systemMessage" }
    var inputKeyPrompt: String { "prompt" }
    var outputKeyResult: String { "result" }

    var agentName: String {
        String(describing: type(of: self))
    }

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
    public var inputs: RTSInput = [:]

    public init(
        llmProvider: RTSLLMProvider,
        name: String? = nil,
        tools: [any RTSToolNode] = [],
        systemMessage: String? = nil
    ) {
        self.agentName = name ?? "Agent"
        self.tools = tools
        self.llmProvider = llmProvider
        if let systemMessage {
            inputs[inputKeySystemMessage] = .string(systemMessage)
        }
    }
}
