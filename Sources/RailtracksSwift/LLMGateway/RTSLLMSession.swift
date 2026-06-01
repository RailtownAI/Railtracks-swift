//
//  RTSLLMSession.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-04-29.
//

import Foundation
import Combine
import Conduit

protocol MessagePublisher {
    var messagePublisher: AnyPublisher<[RTSMessage], Never> { get }
}

/// Encapsulation layer for LLM session underneath
public final class RTSLLMSession: Sendable {
    private let _run: @Sendable (String, UUID?) async throws -> String
    private let _setSystemPrompt: @Sendable (String, UUID?) -> Void
    private let _messages: (@Sendable () -> [RTSMessage])
    let messageSubject: BufferedPassthroughSubject<[RTSMessage]>
    private let agentName: String

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
        messageSubject: BufferedPassthroughSubject<[RTSMessage]>,
        agentName: String
    ) {
        self._run = run
        self._setSystemPrompt = setSystemPrompt
        self._messages = message
        self.messageSubject = messageSubject
        self.agentName = agentName
    }

    public func run(_ prompt: String) async throws -> String {
        try await run(prompt, runID: nil)
    }

    func run(_ prompt: String, runID: UUID) async throws -> String {
        try await run(prompt, runID: Optional(runID))
    }

    private func run(_ prompt: String, runID: UUID?) async throws -> String {
        let response = try await _run(prompt, runID)
        #if DEBUG
        do {
            let encoder = JSONEncoder()
            // petty format cost extra storage and will be an issue when JSON file size is of concern
            encoder.outputFormatting = .prettyPrinted
            let json = try encoder.encode(self.messages())
            log.trace("💎 Messages: \(String(data: json, encoding: .utf8) ?? "<invalid JSON data>")")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("debug_\(agentName)_\(runID?.uuidString ?? "nil")_messages")
                .appendingPathExtension("json")
            try json.write(to: url)
            log.debug("💎 RTSLLMSession: message log written to \(url.path)")
        } catch {
            log.debug("☠️💎 RTSLLMSession: failed to write message log: \(error)")
        }
        #endif
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
}

extension RTSLLMSession: MessagePublisher {
    var messagePublisher: AnyPublisher<[RTSMessage], Never> {
        return messageSubject.replayPublisher
    }
}

// MARK: - static Builder

extension RTSLLMSession {
    static func build(
        appleAI: AppleAISession,
        agentNode: any RTSAgentNode
    ) -> RTSLLMSession {
        let agentName = agentNode.agentName
        let runIDMap = RunIDMap()
        let relay = BufferedPassthroughSubject<[RTSMessage]>()
        return RTSLLMSession(
            run: { prompt, runID in
                let beforeCount = appleAI.messages().count
                let response = try await appleAI.send(prompt)
                if let runID {
                    let newMessages = Array(appleAI.messages().dropFirst(beforeCount))
                    for message in newMessages {
                        runIDMap.set(runID, for: message.id)
                    }
                    let stamped = newMessages.map { message -> RTSMessage in
                        var m = message.stamped(runID: runID)
                        if m.role == .assistant {
                            m = m.stampingTokenCounts(
                                input: response.inputTokens,
                                output: response.outputTokens,
                                latency: response.latency,
                                providerName: RTSLLMProvider.appleAI.providerName
                            )
                        }
                        return m
                    }
                    relay.send(stamped)
                }
                return response.text
            },
            setSystemPrompt: { message, runID in
                // setInstruction recreates the session so transcript resets —
                // capture new messages after the reset, not before.
                appleAI.setInstruction(message)
                if let runID {
                    let newMessages = appleAI.messages()
                    for message in newMessages {
                        runIDMap.set(runID, for: message.id)
                    }
                    relay.send(newMessages.map { $0.stamped(runID: runID) })
                }
            },
            message: {
                appleAI.messages().map { $0.stamped(runID: runIDMap[$0.id]) }
            },
            messageSubject: relay,
            agentName: agentName
        )
    }

    static func build<P: AIProvider & TextGenerator>(
        provider: P,
        model: P.ModelID,
        agentNode: any RTSAgentNode,
        conduitTools: [any Tool]
    ) throws -> RTSLLMSession {
        let agentName = agentNode.agentName
        let providerName = agentNode.llmProvider.providerName
        log.debug("💎 RTSLLMSession: registering tools: [\(conduitTools.map({ $0.name }))]")
        let chatSession = ChatSession(provider: provider, model: model)
        if !conduitTools.isEmpty {
            chatSession.config = chatSession.config.tools(conduitTools)
            chatSession.toolExecutor = ToolExecutor(tools: conduitTools)
        }
        if let schema = agentNode.outputSchema {
            let generationSchema = try schema.toGenerationSchema()
            chatSession.config = chatSession.config
                .responseFormat(.jsonSchema(name: schema.name, schema: generationSchema))
                .maxTokens(agentNode.outputSchemaMaxToken)
        }
        let runIDMap = RunIDMap()
        let relay = BufferedPassthroughSubject<[RTSMessage]>()
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
                    let rtsMessages = newMessages.map { $0.toRTSMessage(runID: runIDMap[$0.id], providerName: providerName) }
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
                    let rtsMessages = newMessages.map { $0.toRTSMessage(runID: runIDMap[$0.id], providerName: providerName) }
                    relay.send(rtsMessages)
                    log.trace("💎 [\(agentName)] setSystemPrompt(\(runID)) associated \(newMessages.count) message(s): \(newMessages.map { "[\($0.role):\($0.id)]" })")
                }
            },
            message: {
                chatSession.messages.map { $0.toRTSMessage(runID: runIDMap[$0.id], providerName: providerName) }
            },
            messageSubject: relay,
            agentName: agentName
        )
    }
}

private extension RTSMessage {
    func stamped(runID: UUID?) -> RTSMessage {
        RTSMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            metadata: metadata,
            runID: runID
        )
    }

    func stampingTokenCounts(
        input: Int?,
        output: Int?,
        latency: Double?,
        providerName: String?
    ) -> RTSMessage {
        let existing = metadata
        let updated = RTSMessageMetadata(
            tokenCount: output ?? existing?.tokenCount,
            inputTokenCount: input ?? existing?.inputTokenCount,
            generationTime: latency ?? existing?.generationTime,
            model: existing?.model ?? providerName,
            providerName: providerName ?? existing?.providerName,
            tokensPerSecond: existing?.tokensPerSecond,
            providerExtra: existing?.providerExtra,
            custom: existing?.custom,
            toolCalls: existing?.toolCalls
        )
        return RTSMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            metadata: updated,
            runID: runID
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
