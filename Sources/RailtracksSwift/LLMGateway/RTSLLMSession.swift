//
//  RTSLLMSession.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-29.
//

import Foundation
import Combine
import ConduitAdvanced

protocol MessagePublisher {
    var messagePublisher: AnyPublisher<[RTSMessage], Never> { get }
}

/// Encapsulation layer for LLM session underneath
public final class RTSLLMSession: Sendable {
    private let _run: @Sendable (String, UUID?) async throws -> String
    private let _setSystemPrompt: @Sendable (String, UUID?) -> Void
    private let _messages: (@Sendable () -> [RTSMessage])
    nonisolated(unsafe) let messageSubject: PassthroughSubject<[RTSMessage], Never>

    /// - Parameter run: Sends a prompt to the underlying LLM and returns the response text.
    ///   The optional `UUID` is a `runID` that stamps all new messages produced during this call
    ///   so they can be traced back to the node invocation that triggered it.
    /// - Parameter setSystemPrompt: Applies a system prompt to the underlying chat session.
    ///   The optional `UUID` is a `runID` used to stamp the resulting system message, keeping it
    ///   associated with the same node invocation as the subsequent `run` call.
    /// - Parameter message: Returns all messages in the session mapped to `RTSMessage`, with
    ///   `runID` associations injected at read time. Always reflects current session state.
    /// - Parameter messageSubject: Subject through which new messages are published after each
    ///   `run` or `setSystemPrompt` call. Subscribers (e.g. `RTSFlowGraphCollector`) use this
    ///   to receive messages stamped with their `runID` without polling `messages()`.
    init(
        run: @escaping @Sendable (String, UUID?) async throws -> String,
        setSystemPrompt: @escaping @Sendable (String, UUID?) -> Void,
        message: @escaping @Sendable () -> [RTSMessage],
        messageSubject: PassthroughSubject<[RTSMessage], Never>
    ) {
        self._run = run
        self._setSystemPrompt = setSystemPrompt
        self._messages = message
        self.messageSubject = messageSubject
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
            #if DEBUG
            // petty format cost extra storage and will be an issue when JSON file size is of concern
            encoder.outputFormatting = .prettyPrinted
            #endif
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

extension RTSLLMSession: MessagePublisher {
    var messagePublisher: AnyPublisher<[RTSMessage], Never> {
        return messageSubject.eraseToAnyPublisher()
    }
}

// MARK: - static Builder

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
        let runIDMap = RunIDMap()
        let relay = SendablePassthroughSubject<[RTSMessage]>()
        return RTSLLMSession(
            run: { prompt, runID in
                // Capturing ids before send to filter out messages that doesn't belong to latest prompt
                // only works if session is never ran concurrently.  Given each agent own its own session,
                // and there's no intention to have same agent instance used in parallel pipeline
                // this design is safe for now.
                let beforeIds = Set(chatSession.messages.map { $0.id })
                let response = try await chatSession.send(prompt)
                if let runID {
                    let newMessages = chatSession.messages.filter { !beforeIds.contains($0.id) }
                    for message in newMessages {
                        runIDMap.set(runID, for: message.id)
                    }
                    let rtsMessages = newMessages.map { $0.toRTSMessage(runID: runIDMap[$0.id]) }
                    relay.send(rtsMessages)
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
                    let rtsMessages = newMessages.map { $0.toRTSMessage(runID: runIDMap[$0.id]) }
                    relay.send(rtsMessages)
                    log.trace("💎 [\(agentName)] setSystemPrompt(\(runID)) associated \(newMessages.count) message(s): \(newMessages.map { "[\($0.role):\($0.id)]" })")
                }
            },
            message: {
                chatSession.messages.map { $0.toRTSMessage(runID: runIDMap[$0.id]) }
            },
            messageSubject: relay.subject
        )
    }
}

// MARK: - runIDMap

private final class RunIDMap: @unchecked Sendable {
    /// [messageID: runID]
    private var storage: [UUID: UUID] = [:]
    private let lock = NSLock()

    func set(_ runID: UUID, for messageID: UUID) {
        lock.withLock { storage[messageID] = runID }
    }

    subscript(_ messageID: UUID) -> UUID? {
        lock.withLock { storage[messageID] }
    }
}
