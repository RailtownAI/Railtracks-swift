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
    private let _run: @Sendable (String, [RTSImage], UUID?) async throws -> String
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
        run: @escaping @Sendable (String, [RTSImage], UUID?) async throws -> String,
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
        try await run(prompt, images: [], runID: nil)
    }

    func run(_ prompt: String, runID: RTSRunID) async throws -> String {
        try await run(prompt, images: [], runID: Optional(runID))
    }

    func run(_ prompt: String, images: [RTSImage], runID: RTSRunID) async throws -> String {
        try await run(prompt, images: images, runID: Optional(runID))
    }

    private func run(_ prompt: String, images: [RTSImage], runID: RTSRunID?) async throws -> String {
        let response = try await _run(prompt, images, runID)
        #if DEBUG
        guard RailtracksSwift.debugMessageFileEnabled else {
            return response
        }
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

    func setSystemPrompt(_ message: String, runID: RTSRunID) {
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
    @available(macOS 26, iOS 26, *)
    static func build(
        appleAI: AppleAISession,
        agentNode: any RTSAgentNode
    ) -> RTSLLMSession {
        let agentName = agentNode.agentName
        let provider = agentNode.llmProvider
        let providerName = provider.providerName
        // `.appleAI` has always recorded its provider name as the model; kept so existing traces
        // do not change. `.foundationModel` records its real model id, which is the pricing key.
        let modelName: String
        if case .foundationModel = provider {
            modelName = provider.modelID
        } else {
            modelName = providerName
        }
        let runIDMap = RunIDMap()
        let relay = BufferedPassthroughSubject<[RTSMessage]>()
        return RTSLLMSession(
            run: { prompt, images, runID in
                if !images.isEmpty {
                    log.warning("⚠️ [\(agentName)] \(providerName) via FoundationModels is text-only here; ignoring \(images.count) image input(s).")
                }
                let beforeCount = appleAI.messages().count
                let publishNewMessages: (AppleAIResponse?) -> Void = { response in
                    guard let runID else { return }
                    let newMessages = Array(appleAI.messages().dropFirst(beforeCount))
                    for message in newMessages {
                        runIDMap.set(runID, for: message.id)
                    }
                    let stamped = stampFoundationModelsMessages(
                        newMessages,
                        runID: runID,
                        response: response,
                        model: modelName,
                        providerName: providerName
                    )
                    relay.send(stamped)
                }
                do {
                    let response = try await appleAI.send(prompt)
                    publishNewMessages(response)
                    return response.text
                } catch {
                    publishNewMessages(nil)
                    throw error
                }
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
        conduitTools: [any Tool],
        applyProviderOptions: @escaping @Sendable (inout GenerateConfig, RTSRequestModalities) -> Void
    ) throws -> RTSLLMSession {
        let agentName = agentNode.agentName
        let providerName = agentNode.llmProvider.providerName
        log.debug("💎 \(agentNode.agentName) - RTSLLMSession: registering tools: [\(conduitTools.map({ $0.name }))]")
        let chatSession = ChatSession(provider: provider, model: model)
        if !conduitTools.isEmpty {
            chatSession.config = chatSession.config.tools(conduitTools)
            chatSession.toolExecutor = ToolExecutor(tools: conduitTools)
        }
        if let schema = agentNode.outputSchema {
            let generationSchema = try schema.toGenerationSchema()
            // OpenAI applies the same identifier rule to the response-format name as to tool names.
            let schemaName = RTSProviderSafeName.sanitized(schema.name)
            if schemaName != schema.name {
                log.warning("⚠️ [\(agentName)] output schema name '\(schema.name)' rewritten to '\(schemaName)' to satisfy provider naming rules")
            }
            chatSession.config = chatSession.config
                .responseFormat(.jsonSchema(name: schemaName, schema: generationSchema))
                .maxTokens(agentNode.outputSchemaMaxToken)
        }
        let runIDMap = RunIDMap()
        let relay = BufferedPassthroughSubject<[RTSMessage]>()
        return RTSLLMSession(
            run: { prompt, images, runID in
                // Capturing ids before send to filter out messages that doesn't belong to latest prompt
                // only works if session is never ran concurrently.  Given each agent own its own session,
                // and there's no intention to have same agent instance used in parallel pipeline
                // this design is safe for now.
                let beforeIds = Set(chatSession.messages.map { $0.id })
                let publishNewMessages: () -> Void = {
                    guard let runID else { return }
                    let newMessages = chatSession.messages.filter { !beforeIds.contains($0.id) }
                    for message in newMessages {
                        runIDMap.set(runID, for: message.id)
                    }
                    let rtsMessages = newMessages.map { $0.toRTSMessage(runID: runIDMap[$0.id], providerName: providerName) }
                    relay.send(rtsMessages)
                    log.trace("💎 [\(agentName)] run(\(runID)) associated \(newMessages.count) message(s): \(newMessages.map { "[\($0.role):\($0.id)]" })")
                }
                do {
                    let content: Message.Content
                    if images.isEmpty {
                        content = .text(prompt)
                    } else {
                        content = .parts([.text(prompt)] + images.map {
                            .image(Message.ImageContent(base64Data: $0.base64Data, mimeType: $0.mimeType))
                        })
                    }
                    // Provider-specific settings, applied per request through a closure so this
                    // builder stays provider-agnostic — only the gateway's per-provider switch knows
                    // what they are, and only the options themselves know which modalities they
                    // apply to. Derived from `chatSession.config` so the tools and output schema set
                    // above are carried into the override rather than replaced by it.
                    var requestConfig = chatSession.config
                    applyProviderOptions(&requestConfig, RTSRequestModalities(content))
                    let response = try await chatSession.send(content, config: requestConfig)
                    publishNewMessages()
                    return response
                } catch {
                    // Publish messages accumulated before the error (user prompt, assistant tool
                    // call, etc.) so the JSON trace and token counts are still recorded.
                    publishNewMessages()
                    throw error
                }
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

/// Stamps the messages one FoundationModels `respond` produced.
///
/// Every assistant message is labelled with its model and provider, so each tool-call turn traces
/// as this provider. Token counts and latency go on the final one only: one `respond` can span
/// several model turns, and its usage is their aggregate — stamping it on every turn would multiply
/// the priced cost by the number of tool-call turns. `response` is `nil` when `respond` threw.
func stampFoundationModelsMessages(
    _ messages: [RTSMessage],
    runID: RTSRunID,
    response: AppleAIResponse?,
    model: String,
    providerName: String
) -> [RTSMessage] {
    let lastAssistantIndex = messages.lastIndex { $0.role == .assistant }
    return messages.enumerated().map { index, message in
        let runStamped = message.stamped(runID: runID)
        guard runStamped.role == .assistant else {
            return runStamped
        }
        let usage = index == lastAssistantIndex ? response : nil
        return runStamped.stampingTokenCounts(
            input: usage?.inputTokens,
            output: usage?.outputTokens,
            latency: usage?.latency,
            model: model,
            providerName: providerName
        )
    }
}

private extension RTSMessage {
    func stamped(runID: RTSRunID?) -> RTSMessage {
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
        model: String?,
        providerName: String?
    ) -> RTSMessage {
        let existing = metadata
        let updated = RTSMessageMetadata(
            tokenCount: output ?? existing?.tokenCount,
            inputTokenCount: input ?? existing?.inputTokenCount,
            generationTime: latency ?? existing?.generationTime,
            model: existing?.model ?? model,
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
    private var storage: [UUID: RTSRunID] = [:]
    private let lock = NSLock()

    func set(_ runID: RTSRunID, for messageID: UUID) {
        lock.withLock { storage[messageID] = runID }
    }

    subscript(_ messageID: UUID) -> RTSRunID? {
        lock.withLock { storage[messageID] }
    }
}
