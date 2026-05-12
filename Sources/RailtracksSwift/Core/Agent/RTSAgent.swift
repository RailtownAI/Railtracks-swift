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
    var llmSession: RTSLLMSession { get }
}

public extension RTSAgentNode {
    var inputKeySystemMessage: String { "stemMessage" }
    var inputKeyPrompt: String { "prompt" }
    var outputKeyResult: String { "result" }
    
    public var agentName: String {
        String(describing: type(of: self))
    }
    
    public func name() -> String { agentName }

    public func invoke() async throws -> RTSOutput {
        try await invoke(runID: nil)
    }

    func invoke(runID: UUID) async throws -> RTSOutput {
        try await invoke(runID: Optional(runID))
    }

    private func invoke(runID: UUID?) async throws -> RTSOutput {
        guard case let .string(prompt) = inputs[inputKeyPrompt] else {
            throw RTSError.missingInput("Agent \(agentName) missing prompt")
        }
        if case let .string(systemMessage) = inputs[inputKeySystemMessage] {
            if let runID {
                llmSession.setSystemPrompt(systemMessage, runID: runID)
            } else {
                llmSession.setSystemPrompt(systemMessage)
            }
        }
        do {
            let result = if let runID {
                try await llmSession.run(prompt, runID: runID)
            } else {
                try await llmSession.run(prompt)
            }
            return [outputKeyResult: .string(result)]
        } catch {
            log.debug("agent(\(id)) failed at running prompt: \(prompt) | \(error)")
            throw error
        }
    }
    
//    public func run(
////        llmSession: RTSLLMSession,
//        prompt: String,
//        systemMessage: String? = nil
//    ) async throws -> String {
//        var copy = self
////        copy.llmSession = llmSession
//        var input: RTSInput = inputs
//        input[inputKeyPrompt] = .string(prompt)
//        if let systemMessage = systemMessage {
//            input[inputKeySystemMessage] = .string(systemMessage)
//        }
//        copy.inputs = input
//        let output = try await copy.invoke()
//        if case let .string(result) = output[outputKeyResult] {
//            return result
//        } else {
//            throw RTSError.missingOutput("Agent \(agentName) missing result")
//        }
////        if let systemMessage = systemMessage {
////            llmSession.setSystemPrompt(systemMessage)
////        }
////        
////        do {
////            return try await llmSession.run(prompt)
////        } catch {
////            log.debug("agent(\(id)) failed at running prompt: \(prompt) | \(error)")
////            throw error
////        }
//    }
}

public struct RTSAgent: RTSAgentNode {
    public let id: UUID = UUID()
    public let agentName: String
    public let llmSession: RTSLLMSession
    public var inputs: RTSInput = [:]
    public var outputs: RTSOutput = [:]
    
    public init(
        llmSession: RTSLLMSession,
        name: String? = nil,
        systemMessage: String? = nil
    ) {
        self.llmSession = llmSession
        self.agentName = name ?? "Agent"
        if let systemMessage = systemMessage {
            inputs[inputKeySystemMessage] = .string(systemMessage)
        }
    }
}

///// Representation of Agent node in Railtracks pipeline
//public class RTSAgent: @unchecked Sendable {
//    // TODO: when RTAgent comply to RTSNode protocol Sendable will be inherited, remove Sendable here then
//    public let id = UUID()
//    let _name: String
////    let llm: RTSLLMSession
//    let systemMessage: String?
//
//    public init(
////        llm: RTSLLMSession,
//        name: String,
//        systemMessage: String? = nil
//    ) {
////        self.llm = llm
//        self._name = name
//        self.systemMessage = systemMessage
//    }
//    
////    public func run(_ prompt: String) async throws -> String? {
////        if let systemMessage = systemMessage {
////            llm.setSystemPrompt(systemMessage)
////        }
////        do {
////            return try await llm.run(prompt)
////        } catch {
////            log.debug("agent(\(id)) failed at running prompt: \(prompt) | \(error)")
////            throw error
////        }
////    }
//}
