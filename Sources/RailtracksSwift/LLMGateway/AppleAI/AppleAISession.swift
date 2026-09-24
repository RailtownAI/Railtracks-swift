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
    typealias MakeSession = @Sendable (_ instructions: String?, _ tools: [any Tool]) -> LanguageModelSession

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
        let startedAt = Date()
        let responseText: String
        let metrics: AppleAIResponse
        if let schema = outputSchema {
            let response = try await currentSession.respond(to: prompt, schema: schema)
            responseText = response.content.jsonString
            metrics = responseMetrics(from: response, text: responseText, startedAt: startedAt)
        } else {
            let response = try await currentSession.respond(to: prompt)
            responseText = response.content
            metrics = responseMetrics(from: response, text: responseText, startedAt: startedAt)
        }
        let newMessages = currentSession.transcript.dropFirst(beforeCount).compactMap { $0.toRTSMessage() }
        let rawCount = currentSession.transcript.count - beforeCount
        log.debug("🍎 send: \(rawCount) new transcript entries, \(newMessages.count) converted to RTSMessage")
        lock.withLock {
            _messages.append(contentsOf: newMessages)
        }
        return metrics
    }

    /// Token counts and latency for one `respond`, which may span several model turns when tools
    /// are called — `usage` is their aggregate.
    ///
    /// Latency is wall clock: FoundationModels reports no duration.
    private func responseMetrics<Content>(
        from response: LanguageModelSession.Response<Content>,
        text: String,
        startedAt: Date
    ) -> AppleAIResponse {
        // OS26-FLOOR: `Response.usage` is OS 27 API. Below that, fall back to the Mirror probe;
        // delete this guard and `extractResponseMetrics` once OS 26 is dropped.
        guard #available(macOS 27, iOS 27, *) else {
            return extractResponseMetrics(from: response, text: text)
        }
        return AppleAIResponse(
            text: text,
            inputTokens: response.usage.input.totalTokenCount,
            outputTokens: response.usage.output.totalTokenCount,
            latency: Date().timeIntervalSince(startedAt)
        )
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
