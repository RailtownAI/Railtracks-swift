//
//  RTSAgent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-24.
//

import Foundation
import Logging

/// Representation of Agent node in Railtracks pipeline
public class RTAgent {
    let id = UUID()
    let llm: RTSLLMSession
    let systemMessage: String

    public init(
        llm: RTSLLMSession,
        systemMessage: String
    ) {
        self.llm = llm
        self.systemMessage = systemMessage
    }
    
    public func run(_ prompt: String) async throws -> String? {
        do {
            log.trace("agent starts to run prompt: \(prompt)")
            return try await llm.run(prompt)
        } catch {
            log.debug("agent(\(id))failed at running prompt: \(prompt) | \(error)")
            throw error
        }
        return nil
    }
}
