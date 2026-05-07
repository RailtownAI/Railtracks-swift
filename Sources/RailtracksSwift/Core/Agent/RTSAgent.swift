//
//  RTSAgent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-24.
//

import Foundation
import Logging

/// Representation of Agent node in Railtracks pipeline
public class RTAgent: @unchecked Sendable {
    // TODO: when RTAgent comply to RTSNode protocol Sendable will be inherited, remove Sendable here then
    let id = UUID()
    let llm: RTSLLMSession
    let systemMessage: String?

    public init(
        llm: RTSLLMSession,
        systemMessage: String? = nil
    ) {
        self.llm = llm
        self.systemMessage = systemMessage
    }
    
    public func run(_ prompt: String) async throws -> String? {
        if let systemMessage = systemMessage {
            llm.setSystemPrompt(systemMessage)
        }
        do {
            return try await llm.run(prompt)
        } catch {
            log.debug("agent(\(id)) failed at running prompt: \(prompt) | \(error)")
            throw error
        }
    }
}
