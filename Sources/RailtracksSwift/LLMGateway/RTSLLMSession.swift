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
    private let _run: @Sendable (String, UUID?) async throws -> String
    private let _setSystemPrompt: @Sendable (String, UUID?) -> Void
    private let _messages: (@Sendable () -> [RTSMessage])

    init(
        run: @escaping @Sendable (String, UUID?) async throws -> String,
        setSystemPrompt: @escaping @Sendable (String, UUID?) -> Void,
        message: @escaping @Sendable () -> [RTSMessage]
    ) {
        self._run = run
        self._setSystemPrompt = setSystemPrompt
        self._messages = message
    }

    public func run(_ prompt: String) async throws -> String {
        try await run(prompt, runID: nil)
    }

    func run(_ prompt: String, runID: UUID) async throws -> String {
        try await run(prompt, runID: Optional(runID))
    }

    private func run(_ prompt: String, runID: UUID?) async throws -> String {
        let response = try await _run(prompt, runID)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let json = try encoder.encode(self.messages())
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
        _setSystemPrompt(message, nil)
    }

    func setSystemPrompt(_ message: String, runID: UUID) {
        _setSystemPrompt(message, runID)
    }
    
    public func messages() -> [RTSMessage] {
        return _messages()
    }
    
    public func logFileName() -> String {
        // TODO: implement json file name logic
        return "temporary_json_log"
    }
}

// MARK: - runIDMap

private final class runIDMap: @unchecked Sendable {
    private var storage: [UUID: UUID] = [:]
    private let lock = NSLock()

    func set(_ runID: UUID, for messageId: UUID) {
        lock.withLock { storage[messageId] = runID }
    }

    subscript(_ messageId: UUID) -> UUID? {
        lock.withLock { storage[messageId] }
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
        invoker: RTSNodeInvoker,
        agentName: String = "Agent"
    ) -> RTSLLMSession {
        log.debug("💎 RTSLLMSession: registering tools: [\(tools.map({ $0.name() }))]")
        let chatSession = ChatSession(provider: provider, model: model)
        let conduitTools = tools.map { $0.asConduitTool(invoker: invoker, createdBy: agentName) }
        if !conduitTools.isEmpty {
            chatSession.config = chatSession.config.tools(conduitTools)
            chatSession.toolExecutor = ToolExecutor(tools: conduitTools)
        }
        let runIDMap = runIDMap()
        return RTSLLMSession(
            run: { prompt, runID in
                let beforeIds = Set(chatSession.messages.map { $0.id })
                let response = try await chatSession.send(prompt)
                if let runID {
                    let newMessages = chatSession.messages.filter { !beforeIds.contains($0.id) }
                    for message in newMessages {
                        runIDMap.set(runID, for: message.id)
                    }
                    log.trace("💎 [\(agentName)] run(\(runID)) associated \(newMessages.count) message(s): \(newMessages.map { "[\($0.role):\($0.id)]" })")
                }
                return response
            },
            setSystemPrompt: { message, runID in
                let beforeIds = Set(chatSession.messages.map { $0.id })
                chatSession.setSystemPrompt(message)
                if let runID {
                    let newMessages = chatSession.messages.filter { !beforeIds.contains($0.id) }
                    for message in newMessages {
                        runIDMap.set(runID, for: message.id)
                    }
                    log.trace("💎 [\(agentName)] setSystemPrompt(\(runID)) associated \(newMessages.count) message(s): \(newMessages.map { "[\($0.role):\($0.id)]" })")
                }
            },
            message: { chatSession.messages.map { $0.toRTSMessage(runID: runIDMap[$0.id]) } }
        )
    }
}
