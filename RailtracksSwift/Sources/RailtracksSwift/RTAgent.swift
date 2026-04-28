//
//  RTAgent.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-24.
//

import Foundation
import ConduitAdvanced
import Logging
//import ConduitAdvanced
//import Logging

public class RTAgent {
    //TODO: setup global logger
    let logger = Logger(label: "railtracks-swift")
    
    let id = UUID()
    let llm: Session
    let systemMessage: String

    public init(
        llm: Session,
        systemMessage: String
    ) {
        self.llm = llm
        self.systemMessage = systemMessage
    }
    
    public func run(_ prompt: String) async throws -> String? {
        do {
            return try await llm.run(prompt)
        } catch {
            logger.debug("agent(\(id))failed at running prompt: \(prompt) | \(error)")
        }
        return nil
    }
}
