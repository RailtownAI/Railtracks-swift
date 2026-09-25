//
//  AppleAISession.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-27.
//

import Foundation
import FoundationModels

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
final class AppleAISession: @unchecked Sendable {
    /// Builds a `LanguageModelSession` from optional instructions and the bridged tools.
    ///
    /// The one thing that differs between `.appleAI` (the system model) and `.foundationModel`
    /// (any `LanguageModel`, OS 27). A closure rather than a stored `any LanguageModel`, because a
    /// stored property cannot carry a newer availability than this OS 26 class.
    typealias MakeSession = @Sendable (
        _ instructions: String?,
        _ tools: [any Tool]
    ) -> LanguageModelSession

    private var session: LanguageModelSession
    private let sessionTools: [any Tool]
    private let outputSchema: GenerationSchema?
    private let makeSession: MakeSession
    private var _messages: [RTSMessage] = []
    private let lock = NSLock()

    private init(
        tools: [any Tool],
        outputSchema: GenerationSchema?,
        makeSession: @escaping MakeSession
    ) {
        self.sessionTools = tools
        self.outputSchema = outputSchema
        self.makeSession = makeSession
        self.session = makeSession(nil, tools)
    }

    /// Applies a system instruction by recreating the session and capturing
    /// the resulting transcript entry (instructions) immediately.
    func setInstruction(_ instruction: String) {
        let newSession = makeSession(instruction, sessionTools)
        let newMessages = newSession.transcript.compactMap { $0.toRTSMessage() }
        lock.withLock {
            session = newSession
            _messages = newMessages
        }
    }

    func send(_ prompt: String) async throws -> AppleAIResponse {
        let currentSession = lock.withLock { session }
        let beforeCount = currentSession.transcript.count
        let usageBefore = Self.sessionTokenTotals(of: currentSession)
        let startedAt = Date()
        let responseText: String
        let metrics: AppleAIResponse
        if let schema = outputSchema {
            let response = try await currentSession.respond(to: prompt, schema: schema)
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
            let response = try await currentSession.respond(to: prompt)
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
        let converted = currentSession.transcript
            .dropFirst(beforeCount)
            .compactMap { $0.toRTSMessage() }
        let newMessages = mergingConsecutiveAssistantMessages(converted)
        let rawCount = currentSession.transcript.count - beforeCount
        log.debug(
            "🍎 send: \(rawCount) new transcript entries, \(newMessages.count) converted to RTSMessage"
        )
        lock.withLock {
            _messages.append(contentsOf: newMessages)
        }
        return metrics
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
        // OS26-FLOOR: `LanguageModelSession.usage` is OS 27 API.
        guard #available(macOS 27, iOS 27, *) else {
            return nil
        }
        return TokenTotals(
            input: session.usage.input.totalTokenCount,
            output: session.usage.output.totalTokenCount
        )
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
        lock.withLock { _messages }
    }

    /// Builds an `AppleAISession` from `agentNode.tools`, wrapping each tool in its
    /// appropriate bridge. `RTSAgentTool` becomes `RTSAppleAIAgentToolBridge`;
    /// `RTSAppleAIToolNode` becomes `RTSAppleAIToolBridge`. Other tools are unsupported.
    /// Returns non-conforming tools separately so the caller can warn about them.
    ///
    /// `sessionFactory` is `nil` for the on-device system model; `.foundationModel` passes one
    /// built from its `LanguageModel`.
    static func build(
        fromAgentTools tools: [any RTSToolNode],
        invoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode,
        makeSubSession: @escaping @Sendable (any RTSAgentNode) throws -> RTSLLMSession,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void,
        sessionFactory: MakeSession? = nil
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
                        onNewSession: onNewSession,
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
                        onNewSession: onNewSession,
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
            }
        )
        return (session, unsupportedTools)
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
                content: .text(joinedText(of: prompt.segments)),
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
        case .reasoning(let reasoning):
            // OS 27: a model's thinking, e.g. Claude's adaptive thinking. Deliberately not a
            // message — `RTSLLMRoundTrip` makes one round trip per assistant message, so mapping it
            // to `.assistant` would add a phantom round trip to `llm_details` and the `llm.*` events.
            //
            // Logged as a size only: the text restates the conversation, and the console must not
            // become a way around what the trace keeps out (see the AppleAI PII guardrail).
            log.debug("🍎 reasoning entry skipped: \(joinedText(of: reasoning.segments).count) characters")
            return nil
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
                // `.attachment` (OS 27): an image has no text form.
                return nil
            }
        }
        .joined(separator: " ")
}
