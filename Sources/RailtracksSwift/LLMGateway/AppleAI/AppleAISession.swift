//
//  AppleAISession.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-27.
//

import Foundation
import FoundationModels
import Synchronization

/// Wraps `LanguageModelSession` and exposes the subset of its API that
/// `RTSLLMSession` needs, mirroring the role `ChatSession` plays for
/// Conduit-backed providers.
///
/// `LanguageModelSession` takes instructions and tools at init time only,
/// so this class recreates the session when a new instruction is applied.
/// Messages are appended immediately after each `send` or `setInstruction`
/// so timestamps reflect when each entry was actually produced.
struct AppleAIResponse {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
    let latency: Double?
}

@available(macOS 26, iOS 26, *)
final class AppleAISession: Sendable {
    /// Builds a `LanguageModelSession` from optional instructions and the bridged tools.
    ///
    /// The one thing that differs between `.appleAI` (the system model) and `.foundationModel`
    /// (any `LanguageModel`, OS 27). A closure rather than a stored `any LanguageModel`, because a
    /// stored property cannot carry a newer availability than this OS 26 class.
    typealias MakeSession = @Sendable (
        _ instructions: String?,
        _ tools: [any Tool]
    ) -> LanguageModelSession

    /// What changes after `init`: the current session and the messages recorded so far.
    /// `setInstruction` replaces both at once, so they share one lock.
    private struct State {
        var session: LanguageModelSession
        var messages: [RTSMessage] = []
    }

    private let state: Mutex<State>
    private let sessionTools: [any Tool]
    private let outputSchema: GenerationSchema?
    private let makeSession: MakeSession
    /// Whether the model takes image input. Read once at build, because a `LanguageModelSession`
    /// does not expose its model. A plain `Bool`, so this OS 26 class can hold it.
    private let supportsVision: Bool
    /// The agent's name, for log messages.
    private let agentName: String
    /// The provider's description, naming the model in errors and log messages.
    private let modelDescription: String

    private init(
        tools: [any Tool],
        outputSchema: GenerationSchema?,
        makeSession: @escaping MakeSession,
        supportsVision: Bool,
        agentName: String,
        modelDescription: String
    ) {
        self.sessionTools = tools
        self.outputSchema = outputSchema
        self.makeSession = makeSession
        self.supportsVision = supportsVision
        self.agentName = agentName
        self.modelDescription = modelDescription
        self.state = Mutex(State(session: makeSession(nil, tools)))
    }

    /// Applies a system instruction by recreating the session and capturing
    /// the resulting transcript entry (instructions) immediately.
    func setInstruction(_ instruction: String) {
        let newSession = makeSession(instruction, sessionTools)
        let newMessages = newSession.transcript.compactMap { $0.toRTSMessage() }
        state.withLock { state in
            state.session = newSession
            state.messages = newMessages
        }
    }

    /// Sends `prompt`, with `images` attached after its text where the platform and model allow.
    ///
    /// Without images the `String` overloads of `respond` are used, exactly as before image support.
    /// Below OS 27 images are dropped with a warning; on a model without vision they fail with
    /// `RTSError.invalidInvocation`, and undecodable ones with `RTSError.decodingFailed`, both before
    /// anything is sent. Those two failures still record the prompt, images included, as a failed
    /// `respond` does. See `RTSAppleAIImageDelivery`.
    func send(_ prompt: String, images: [RTSImage] = []) async throws -> AppleAIResponse {
        let unsentPrompt = RTSMessage.Content.sentPrompt(prompt, attachedImageCount: images.count)
        let delivery = try recordingOnFailure(unsentPrompt) {
            try RTSAppleAIImageDelivery.decide(
                imageCount: images.count,
                platformSupportsImages: RTSAppleAIImageDelivery.platformSupportsImages,
                modelSupportsVision: supportsVision,
                modelDescription: modelDescription
            )
        }
        switch delivery {
        case .textOnly:
            break
        case .dropped:
            // OS26-FLOOR: below OS 27 Foundation Models has no image input.
            log.warning("⚠️ [\(agentName)] \(modelDescription): image input needs macOS 27 / iOS 27; ignoring \(images.count) image input(s).")
        case .attached:
            // XCODE26-SDK: `Attachment` and `respond(to: Prompt)` with one need the OS 27 SDK
            // (Xcode 27, Swift 6.4). `.attached` is only decided when both are present.
            #if compiler(>=6.4)
            if #available(macOS 27, iOS 27, *) {
                let attachments = try recordingOnFailure(unsentPrompt) {
                    try images.enumerated().map { index, image in
                        try image.foundationModelsAttachment(index: index)
                    }
                }
                let promptWithImages = Prompt {
                    prompt
                    attachments
                }
                return try await respond(
                    recordingAs: .sentPrompt(prompt, attachedImageCount: attachments.count),
                    text: { session in
                        try await session.respond(to: promptWithImages)
                    },
                    structured: { session, schema in
                        try await session.respond(to: promptWithImages, schema: schema)
                    }
                )
            }
            #endif
        }
        return try await respond(
            recordingAs: .sentPrompt(prompt, attachedImageCount: 0),
            text: { session in
                try await session.respond(to: prompt)
            },
            structured: { session, schema in
                try await session.respond(to: prompt, schema: schema)
            }
        )
    }

    /// Runs `prepare`. If it throws, records `unsentPrompt` as the user message, then rethrows.
    ///
    /// For the steps of a send that can fail before `respond`: the vision check and the image
    /// decode. Recording the prompt makes them report like a failed `respond`, whose prompt
    /// `recordFailedSend` records. Without it, whether the failure reached `llm.failure` would
    /// depend on whether the agent's system message was already in the log, since `llm.failure`
    /// is only reported for a session that recorded a message.
    private func recordingOnFailure<Value>(
        _ unsentPrompt: RTSMessage.Content,
        _ prepare: () throws -> Value
    ) throws -> Value {
        do {
            return try prepare()
        } catch {
            let message = RTSMessage(
                id: UUID(),
                role: .user,
                content: unsentPrompt,
                timestamp: Date(),
                metadata: nil,
                runID: nil
            )
            state.withLock { state in
                state.messages.append(message)
            }
            throw error
        }
    }

    /// The plain `respond` on a session, with the prompt the caller chose.
    private typealias RespondText = (
        LanguageModelSession
    ) async throws -> LanguageModelSession.Response<String>

    /// The structured-output `respond` on a session, with the prompt the caller chose.
    private typealias RespondStructured = (
        LanguageModelSession,
        GenerationSchema
    ) async throws -> LanguageModelSession.Response<GeneratedContent>

    /// Runs one `respond` on the current session and records what it left behind: the new transcript
    /// entries on success, or what was sent on failure.
    ///
    /// The two closures are the plain and the structured-output `respond`, so the prompt they send
    /// (text only, or text with attachments) is chosen by the caller. `recordingAs` is that prompt
    /// as a message's content, recorded when a failed `respond` rolls back the transcript.
    private func respond(
        recordingAs sentPrompt: RTSMessage.Content,
        text respondText: RespondText,
        structured respondStructured: RespondStructured
    ) async throws -> AppleAIResponse {
        let currentSession = state.withLock { state in
            state.session
        }
        let beforeCount = currentSession.transcript.count
        let usageBefore = Self.sessionTokenTotals(of: currentSession)
        let startedAt = Date()
        let responseText: String
        let metrics: AppleAIResponse
        do {
            if let schema = outputSchema {
                let response = try await respondStructured(currentSession, schema)
                responseText = response.content.jsonString
                metrics = responseMetrics(
                    from: response,
                    text: responseText,
                    startedAt: startedAt,
                    sessionUsage: (
                        before: usageBefore,
                        after: Self.sessionTokenTotals(of: currentSession)
                    )
                )
            } else {
                let response = try await respondText(currentSession)
                responseText = response.content
                metrics = responseMetrics(
                    from: response,
                    text: responseText,
                    startedAt: startedAt,
                    sessionUsage: (
                        before: usageBefore,
                        after: Self.sessionTokenTotals(of: currentSession)
                    )
                )
            }
        } catch {
            recordFailedSend(
                prompt: sentPrompt,
                startedAt: startedAt,
                session: currentSession,
                transcriptCountBefore: beforeCount,
                usageBefore: usageBefore
            )
            throw error
        }
        let converted = currentSession.transcript
            .dropFirst(beforeCount)
            .compactMap { $0.toRTSMessage() }
        let newMessages = mergingConsecutiveAssistantMessages(converted)
        let rawCount = currentSession.transcript.count - beforeCount
        log.debug(
            "🍎 send: \(rawCount) new transcript entries, \(newMessages.count) converted to RTSMessage"
        )
        state.withLock { state in
            state.messages.append(contentsOf: newMessages)
        }
        return metrics
    }

    /// Records what a failed `respond` leaves behind, so the failure's `llm.*` events show what
    /// was sent.
    ///
    /// A failed `respond` rolls its transcript back: measured on the system model, a cancel during
    /// the second of two tool calls left only the instructions entry, losing the prompt, the first
    /// call and its output. So the prompt is recorded from what was sent, stamped `startedAt`,
    /// when it was sent. The rollback is measured, not documented, so anything the transcript
    /// did keep is used too, with the prompt added only when no user entry was kept, so it is
    /// never recorded twice. Success is unaffected: its messages come from the transcript.
    ///
    /// The session's usage does keep the failed call's tokens. Python's `llm.failure` has no
    /// token fields, so they are only logged.
    private func recordFailedSend(
        prompt: RTSMessage.Content,
        startedAt: Date,
        session: LanguageModelSession,
        transcriptCountBefore: Int,
        usageBefore: TokenTotals?
    ) {
        let kept = mergingConsecutiveAssistantMessages(
            session.transcript
                .dropFirst(transcriptCountBefore)
                .compactMap { $0.toRTSMessage() }
        )
        // The prompt is added unless the transcript kept it, so a partial rollback that kept
        // only tool entries still shows what was sent, first.
        let recorded: [RTSMessage]
        if kept.contains(where: { $0.role == .user }) {
            recorded = kept
        } else {
            let sentPrompt = RTSMessage(
                id: UUID(),
                role: .user,
                content: prompt,
                timestamp: startedAt,
                metadata: nil,
                runID: nil
            )
            recorded = [sentPrompt] + kept
        }
        log.debug("🍎 respond failed: recorded \(recorded.count) message(s), \(kept.count) kept by the transcript")
        if let before = usageBefore, let after = Self.sessionTokenTotals(of: session) {
            let used = TokenTotals(input: after.input - before.input, output: after.output - before.output)
            log.debug("🍎 the failed respond used \(used); not reported, llm.failure has no token fields")
        }
        state.withLock { state in
            state.messages.append(contentsOf: recorded)
        }
    }

    /// Input and output token totals, in a type this OS 26 class can hold —
    /// `LanguageModelSession.Usage` is OS 27 only.
    struct TokenTotals: CustomStringConvertible {
        let input: Int
        let output: Int

        var description: String {
            "\(input) in / \(output) out"
        }
    }

    /// The session's usage: the total tokens across every run so far within this session — a
    /// running total, not the latest run's. `nil` below OS 27.
    private static func sessionTokenTotals(
        of session: LanguageModelSession
    ) -> TokenTotals? {
        // XCODE26-SDK: `usage` exists only in the OS 27 SDK (Xcode 27, Swift 6.4); `@available`
        // cannot hide a symbol the SDK being compiled against does not declare.
        #if compiler(>=6.4)
        // OS26-FLOOR: `LanguageModelSession.usage` is OS 27 API.
        guard #available(macOS 27, iOS 27, *) else {
            return nil
        }
        return TokenTotals(
            input: session.usage.input.totalTokenCount,
            output: session.usage.output.totalTokenCount
        )
        #else
        return nil
        #endif
    }

    /// Token counts and latency for one `respond`.
    ///
    /// One `respond` spans a model call per turn when tools are called, but `Response.usage`
    /// covers only the **last** call — verified against a live Claude run, where it matched the
    /// final call alone and missed the three tool-calling calls before it. So the counts come from
    /// the change in the session's running `usage` across the `respond`. That the session total
    /// accumulates every call is itself not documented, so it is checked: a delta smaller than
    /// `Response.usage` cannot be a sum that includes it, and then the counts are reported as
    /// unknown (`nil`) rather than as a figure that is silently too low.
    ///
    /// Latency is wall clock: FoundationModels reports no duration.
    private func responseMetrics<Content>(
        from response: LanguageModelSession.Response<Content>,
        text: String,
        startedAt: Date,
        sessionUsage: (before: TokenTotals?, after: TokenTotals?)
    ) -> AppleAIResponse {
        // XCODE26-SDK: `Response.usage` exists only in the OS 27 SDK (Xcode 27, Swift 6.4). Built
        // with an older SDK, only the Mirror probe is available.
        #if compiler(>=6.4)
        // OS26-FLOOR: `Response.usage` is OS 27 API. Below that, fall back to the Mirror probe;
        // delete this guard and `extractResponseMetrics` once OS 26 is dropped.
        guard #available(macOS 27, iOS 27, *) else {
            return extractResponseMetrics(from: response, text: text)
        }
        let latency = Date().timeIntervalSince(startedAt)
        let lastCall = TokenTotals(
            input: response.usage.input.totalTokenCount,
            output: response.usage.output.totalTokenCount
        )
        let usage = Self.respondUsage(lastCall: lastCall, sessionUsage: sessionUsage)
        return AppleAIResponse(
            text: text,
            inputTokens: usage?.input,
            outputTokens: usage?.output,
            latency: latency
        )
        #else
        return extractResponseMetrics(from: response, text: text)
        #endif
    }

    /// The session-usage delta across the `respond` when it is a plausible sum of every call, or
    /// `nil` when it cannot be trusted — see ``responseMetrics(from:text:startedAt:sessionUsage:)``.
    ///
    /// Deliberately not a fallback to `Response.usage`: that covers only the last model call, so on
    /// a respond with N tool-calling turns it would report roughly 1/N of the real tokens and cost,
    /// with nothing in the trace to say so.
    ///
    /// - Parameters:
    ///   - lastCall: `Response.usage` — the tokens of the run's last model call only.
    ///   - sessionUsage: the session's usage — the total tokens across every run so far within this
    ///     session — read just before this run (`before`) and just after it returns (`after`). The
    ///     model calls in between are not observable: Apple's session drives the tool loop inside
    ///     `respond`.
    static func respondUsage(
        lastCall: TokenTotals,
        sessionUsage: (before: TokenTotals?, after: TokenTotals?)
    ) -> TokenTotals? {
        guard let before = sessionUsage.before, let after = sessionUsage.after else {
            return nil
        }
        // The total tokens between before and after this run: every model call the run made,
        // however many — one for a plain answer, several when tools are called. Measured once per
        // run, never between the calls inside it.
        let sessionDelta = TokenTotals(
            input: after.input - before.input,
            output: after.output - before.output
        )
        log.debug("🍎 usage: Response.usage \(lastCall), session delta \(sessionDelta)")
        guard sessionDelta.input >= lastCall.input, sessionDelta.output >= lastCall.output else {
            log.warning(
                """
                ⚠️🍎 session usage delta \(sessionDelta) is below Response.usage \(lastCall), so it \
                is not a total of every model call; reporting token counts as unknown
                """
            )
            return nil
        }
        return sessionDelta
    }

    private func extractResponseMetrics(from response: some Any, text: String) -> AppleAIResponse {
        let m = Mirror(reflecting: response)
        let input = m.children.first(where: { $0.label == "promptTokenCount" })
            .flatMap { $0.value as? Int }
        let output = m.children.first(where: { $0.label == "responseTokenCount" })
            .flatMap { $0.value as? Int }
        let latency = m.children.first(where: { $0.label == "duration" })?.value as? Double
        return AppleAIResponse(text: text, inputTokens: input, outputTokens: output, latency: latency)
    }

    func messages() -> [RTSMessage] {
        state.withLock { state in
            state.messages
        }
    }

    /// Builds an `AppleAISession` from `agentNode.tools`, wrapping each tool in its
    /// appropriate bridge. `RTSAgentTool` becomes `RTSAppleAIAgentToolBridge`;
    /// `RTSAppleAIToolNode` becomes `RTSAppleAIToolBridge`. Other tools are unsupported.
    /// Returns non-conforming tools separately so the caller can warn about them.
    ///
    /// `sessionFactory` is `nil` for the on-device system model; `.foundationModel` passes one
    /// built from its `LanguageModel`. `supportsVision` is that model's `.vision` capability, read
    /// by the caller because the session cannot report its model.
    static func build(
        fromAgentTools tools: [any RTSToolNode],
        invoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode,
        makeSubSession: @escaping @Sendable (any RTSAgentNode) throws -> RTSLLMSession,
        sessionFactory: MakeSession? = nil,
        supportsVision: Bool
    ) throws -> (session: AppleAISession, unsupported: [any RTSToolNode]) {
        var appleTools: [any Tool] = []
        var unsupportedTools: [any RTSToolNode] = []
        for tool in tools {
            if let agentTool = tool as? RTSAgentTool {
                do {
                    let schema = try agentTool.parameters.toFoundationModelsSchema()
                    let bridge = RTSAppleAIAgentToolBridge(
                        agentTool: agentTool,
                        parameters: schema,
                        makeSession: { try makeSubSession(agentTool.wrappedAgent) },
                        nodeInvoker: invoker,
                        createdBy: createdBy
                    )
                    appleTools.append(bridge)
                } catch {
                    if tool.isRequired {
                        throw RTSError.invalidSchema("Required tool '\(agentTool.toolName)' schema conversion failed: \(error)")
                    }
                    log.warning("⚠️🍎 [\(createdBy.agentName)] RTSAgentTool '\(agentTool.toolName)' schema conversion failed, tool dropped: \(error)")
                    unsupportedTools.append(tool)
                }
            } else if let orchestratorTool = tool as? RTSOrchestratorTool {
                do {
                    let schema = try orchestratorTool.parameters.toFoundationModelsSchema()
                    let bridge = RTSAppleAIOrchestratorToolBridge(
                        orchestratorTool: orchestratorTool,
                        parameters: schema,
                        makeSession: makeSubSession,
                        nodeInvoker: invoker,
                        createdBy: createdBy
                    )
                    appleTools.append(bridge)
                } catch {
                    if tool.isRequired {
                        throw RTSError.invalidSchema("Required tool '\(orchestratorTool.toolName)' schema conversion failed: \(error)")
                    }
                    log.warning("⚠️🍎 [\(createdBy.agentName)] RTSOrchestratorTool '\(orchestratorTool.toolName)' schema conversion failed, tool dropped: \(error)")
                    unsupportedTools.append(tool)
                }
            } else if let appleTool = tool as? any RTSAppleAIToolNode {
                let bridge = appleTool.makeAppleAIBridge(invoker: invoker, createdBy: createdBy)
                          ?? (appleTool as any Tool)
                appleTools.append(bridge)
            } else {
                if tool.isRequired {
                    throw RTSError.invalidSchema("Required tool '\(tool.toolName)' is not supported by AppleAI")
                }
                unsupportedTools.append(tool)
            }
        }
        let schema: GenerationSchema? = try createdBy.outputSchema.map { try $0.toFoundationModelsSchema() }
        let session = AppleAISession(
            tools: appleTools,
            outputSchema: schema,
            makeSession: sessionFactory ?? { instructions, tools in
                makeSystemSession(instruction: instructions, tools: tools)
            },
            supportsVision: supportsVision,
            agentName: createdBy.agentName,
            modelDescription: createdBy.llmProvider.description
        )
        return (session, unsupportedTools)
    }

    /// Whether the on-device system model takes image input. `false` below OS 27, where nothing
    /// can be attached.
    static var systemModelSupportsVision: Bool {
        // XCODE26-SDK: `capabilities` exists only in the OS 27 SDK (Xcode 27, Swift 6.4).
        #if compiler(>=6.4)
        // OS26-FLOOR: `SystemLanguageModel.capabilities` is OS 27 API.
        if #available(macOS 27, iOS 27, *) {
            return RTSAppleAIImageDelivery.supportsVision(SystemLanguageModel.default.capabilities)
        }
        #endif
        return false
    }

    /// A session on the on-device system model.
    private static func makeSystemSession(instruction: String?, tools: [any Tool]) -> LanguageModelSession {
        switch (instruction, tools.isEmpty) {
        case (let inst?, false):
            return LanguageModelSession(tools: tools, instructions: inst)
        case (let inst?, true):
            return LanguageModelSession(instructions: inst)
        case (nil, false):
            return LanguageModelSession(tools: tools)
        case (nil, true):
            return LanguageModelSession()
        }
    }
}

// MARK: - Transcript.Entry → RTSMessage

@available(macOS 26, iOS 26, *)
extension Transcript.Entry {
    func toRTSMessage() -> RTSMessage? {
        let timestamp = Date()
        switch self {
        case .instructions(let instructions):
            return RTSMessage(
                id: UUID(),
                role: .system,
                content: .text(joinedText(of: instructions.segments)),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .prompt(let prompt):
            return RTSMessage(
                id: UUID(),
                role: .user,
                content: promptContent(of: prompt.segments),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .response(let response):
            return RTSMessage(
                id: UUID(),
                role: .assistant,
                content: .text(joinedText(of: response.segments)),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .toolCalls(let toolCalls):
            let text = toolCalls
                .map { "\($0.toolName): \($0.arguments.jsonString)" }
                .joined(separator: "\n")
            return RTSMessage(
                id: UUID(),
                role: .assistant,
                content: .text(text),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .toolOutput(let toolOutput):
            let text = "[\(toolOutput.toolName)] \(joinedText(of: toolOutput.segments))"
            return RTSMessage(
                id: UUID(),
                role: .tool,
                content: .text(text),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        // XCODE26-SDK: `.reasoning` exists only in the OS 27 SDK (Xcode 27, Swift 6.4). An older
        // SDK cannot produce the entry either, so leaving the case out there loses nothing.
        #if compiler(>=6.4)
        case .reasoning(let reasoning):
            // OS 27: a model's thinking, e.g. Claude's adaptive thinking. Deliberately not a
            // message — `RTSLLMRoundTrip` makes one round trip per assistant message, so mapping it
            // to `.assistant` would add a phantom round trip to `llm_details` and the `llm.*` events.
            //
            // Logged as a size only: the text restates the conversation, and the console must not
            // become a way around what the trace keeps out (see the AppleAI PII guardrail).
            log.debug("🍎 reasoning entry skipped: \(joinedText(of: reasoning.segments).count) characters")
            return nil
        #endif
        @unknown default:
            log.debug("🍎 toRTSMessage: unhandled Transcript.Entry case: \(self)")
            return nil
        }
    }
}

/// Merges each run of consecutive assistant messages into one.
///
/// The transcript splits one model call's output into a `.response` entry (its text) and a
/// `.toolCalls` entry — e.g. Claude's narration "Step 2: 50 + 160" and then its `Addition` call.
/// Conduit records such a call as one message, and `RTSLLMRoundTrip` makes one round trip per
/// assistant message, so left split they would trace as two calls. Assistant messages with nothing
/// between them are one call's output: the next call only starts after a tool result.
func mergingConsecutiveAssistantMessages(_ messages: [RTSMessage]) -> [RTSMessage] {
    var merged: [RTSMessage] = []
    for message in messages {
        guard message.role == .assistant, let previous = merged.last, previous.role == .assistant else {
            merged.append(message)
            continue
        }
        merged[merged.count - 1] = RTSMessage(
            id: previous.id,
            role: .assistant,
            content: .text(previous.content.textValue + "\n" + message.content.textValue),
            timestamp: message.timestamp,
            metadata: previous.metadata,
            runID: previous.runID
        )
    }
    return merged
}

/// Joins an entry's segments into one string: text as written, structured content as JSON.
@available(macOS 26, iOS 26, *)
func joinedText(of segments: [Transcript.Segment]) -> String {
    segments
        .compactMap { segment -> String? in
            switch segment {
            case .text(let textSegment):
                return textSegment.content
            case .structure(let structuredSegment):
                return structuredSegment.content.jsonString
            default:
                // `.attachment` (OS 27): an image has no text form. A prompt's attachments are
                // recorded as image parts by `promptContent(of:)`.
                return nil
            }
        }
        .joined(separator: " ")
}

/// A prompt entry's content: plain text, as before image support, unless it holds an attachment,
/// in which case it is `.parts` in segment order, each image a redacted inline descriptor.
@available(macOS 26, iOS 26, *)
func promptContent(of segments: [Transcript.Segment]) -> RTSMessage.Content {
    // XCODE26-SDK: `.attachment` exists only in the OS 27 SDK (Xcode 27, Swift 6.4).
    #if compiler(>=6.4)
    // OS26-FLOOR: attachment segments are OS 27 API, and below it a prompt never holds one.
    if #available(macOS 27, iOS 27, *), let parts = attachmentParts(of: segments) {
        return .parts(parts)
    }
    #endif
    return .text(joinedText(of: segments))
}

// XCODE26-SDK: as above.
#if compiler(>=6.4)
/// The segments as message parts, or `nil` when none is an attachment.
///
/// Only the segment's case is read, never its pixels, so no image data can reach the trace. Images
/// are sent inline, so each is the same `data_uri` descriptor the Conduit path records.
@available(macOS 27, iOS 27, *)
private func attachmentParts(of segments: [Transcript.Segment]) -> [RTSMessage.ContentPart]? {
    var parts: [RTSMessage.ContentPart] = []
    var hasAttachment = false
    for segment in segments {
        switch segment {
        case .text(let textSegment):
            parts.append(.text(textSegment.content))
        case .structure(let structuredSegment):
            parts.append(.text(structuredSegment.content.jsonString))
        case .attachment:
            hasAttachment = true
            parts.append(.image(.redactedInline))
        default:
            continue
        }
    }
    return hasAttachment ? parts : nil
}
#endif

extension RTSMessage.Content {
    /// What a send put in its prompt: the text, then one redacted inline image part per attached
    /// image. Plain text when nothing was attached, matching what the transcript records.
    ///
    /// Recorded when a failed `respond` rolls back the transcript, so the failure's `llm.*` events
    /// still show that images were sent.
    static func sentPrompt(_ text: String, attachedImageCount: Int) -> RTSMessage.Content {
        guard attachedImageCount > 0 else {
            return .text(text)
        }
        let images = Array(repeating: RTSMessage.ContentPart.image(.redactedInline), count: attachedImageCount)
        return .parts([.text(text)] + images)
    }
}
