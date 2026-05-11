//
//  RTSLLMSession.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-29.
//

import Foundation
import ConduitAdvanced

/// Encapsulation layer for LLM session underneath
public final class RTSLLMSession: Sendable {
    private let _run: @Sendable (String) async throws -> String
    private let _setSystemPrompt: @Sendable (String) -> Void
    private let _messages: (@Sendable () -> [RTSMessage])  // TODO: convert Message into non-Conduit specific before exposing it
    
    init(
        run: @escaping @Sendable (String) async throws -> String,
        setSystemPrompt: @escaping @Sendable (String) -> Void,
        message: @escaping @Sendable () -> [RTSMessage]
    ) {
        self._run = run
        self._setSystemPrompt = setSystemPrompt
        self._messages = message
    }
    
    public func run(_ prompt: String) async throws -> String {
        let response = try await _run(prompt)
        do {
            let json = try JSONEncoder().encode(self.messages())
            log.trace("💎 Messages: \(String(data: json, encoding: .utf8) ?? "<invalid JSON data>")")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(logFileName())
                .appendingPathExtension("json")
            try json.write(to: url)
            log.debug("💎 RTSLLMSession: message log written to \(url.path)")
        } catch {
            log.debug("☠️💎 RTSLLMSession: failed to write message log: \(error)")
        }
        return response
    }
    
    public func setSystemPrompt(_ message: String) {
        _setSystemPrompt(message)
    }
    
    public func messages() -> [RTSMessage] {
        return _messages()
    }
    
    public func logFileName() -> String {
        // TODO: implement json file name logic
        return "temporary_json_log"
    }
}

//
// MARK: static Builder
//
extension RTSLLMSession {
    static func build<P: AIProvider & TextGenerator>(
        provider: P,
        model: P.ModelID,
        tools: [any RTSToolNode],
        invoker: RTSNodeInvoker
    ) -> RTSLLMSession {
        log.debug("💎 RTSLLMSession: registering tools: [\(tools.map({ $0.name() }))]")
        let chatSession = ChatSession(provider: provider, model: model)
        let conduitTools = tools.map { $0.asConduitTool(invoker: invoker) }
        if !conduitTools.isEmpty {
            // register tools for llm request body
            chatSession.config = chatSession.config.tools(conduitTools)
            // register tools for execution
            chatSession.toolExecutor = ToolExecutor(tools: conduitTools)
        }
        return RTSLLMSession(
            run: { prompt in try await chatSession.send(prompt) },
            setSystemPrompt: { message in chatSession.setSystemPrompt(message) },
            message: { chatSession.messages.map({ $0.toRTSMessage }) }
        )
    }
}
