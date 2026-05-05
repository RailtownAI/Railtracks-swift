//
//  RTSLLMSession.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-29.
//

import Foundation
import ConduitAdvanced

/// Encapsulation layer for LLM session underneath
//public class RTSLLMSession {
//    let session: Session
//    var systemMessage: String?
//    
//    init(accessPoint: Conduit, model: Model, tools: [RTSToolNode]) throws {
//        let conduitTools = tools.map({ $0.asConduitTool() })
//        self.session = try accessPoint.session(model: model) { options in
//            options.tools {
//                conduitTools
//            }
//        }
//        // TODO: add tools into session
//    }
//    
//    func run(_ prompt: String) async throws -> String {
//        if let systemMessage = self.systemMessage {
//            session.setSystemPrompt(systemMessage)
//        }
//        return try await session.run(prompt)
//    }
//}

public class RTSLLMSession {
    private let _run: @Sendable (String) async throws -> String
    private let _setSystemPrompt: @Sendable (String) -> Void
                                                            
    init(
        run: @escaping @Sendable (String) async throws -> String,
        setSystemPrompt: @escaping @Sendable (String) -> Void
    ) {
        self._run = run
        self._setSystemPrompt = setSystemPrompt
    }
     
    static func build<P: AIProvider & TextGenerator>(
        provider: P,
        model: P.ModelID,
        tools: [any RTSToolNode]
    ) -> RTSLLMSession {
        log.debug("#### RTSLLMSession: registering tools: [\(tools.map({ $0.name() }))]")
        let chatSession = ChatSession(provider: provider, model: model)
        let conduitTools = tools.map { $0.asConduitTool() }
        if !conduitTools.isEmpty {
            chatSession.toolExecutor = ToolExecutor(tools: conduitTools)
        }
        return RTSLLMSession(
            run: { prompt in try await chatSession.send(prompt) },
            setSystemPrompt: { message in chatSession.setSystemPrompt(message) }
        )
    }
                                                                                                                                       
    public func run(_ prompt: String) async throws -> String { try await _run(prompt) }
    public func setSystemPrompt(_ message: String) { _setSystemPrompt(message) }
}
