//
//  RTSLLMSession.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-29.
//

import Foundation
import ConduitAdvanced

/// Encapsulation layer for LLM session underneath
public class RTSLLMSession {
    let session: Session
    
    init(accessPoint: Conduit, model: Model) throws {
        self.session = try accessPoint.session(model: model)
    }
    
    func run(_ prompt: String) async throws -> String {
        return try await session.run(prompt)
    }
}
