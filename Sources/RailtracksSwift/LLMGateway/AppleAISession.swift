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
final class AppleAISession: @unchecked Sendable {
    private var session: LanguageModelSession
    private let sessionTools: [any Tool]
    private var _messages: [RTSMessage] = []
    private let lock = NSLock()

    init(tools: [any Tool] = []) {
        self.sessionTools = tools
        self.session = Self.makeSession(instruction: nil, tools: tools)
    }

    /// Applies a system instruction by recreating the session and capturing
    /// the resulting transcript entry (instructions) immediately.
    func setInstruction(_ instruction: String) {
        let newSession = Self.makeSession(instruction: instruction, tools: sessionTools)
        let newMessages = newSession.transcript.compactMap { $0.toRTSMessage() }
        lock.withLock {
            session = newSession
            _messages = newMessages
        }
    }

    func send(_ prompt: String) async throws -> String {
        let currentSession = lock.withLock { session }
        let beforeCount = currentSession.transcript.count
        let response = try await currentSession.respond(to: prompt)
        let newMessages = currentSession.transcript.dropFirst(beforeCount).compactMap { $0.toRTSMessage() }
        lock.withLock {
            _messages.append(contentsOf: newMessages)
        }
        // TODO: extract response.promptTokenCount and response.responseTokenCount via Mirror
        // and return alongside content so RTSLLMSession can stamp them onto the assistant RTSMessage metadata
        return response.content
    }

    func messages() -> [RTSMessage] {
        lock.withLock { _messages }
    }

    /// Builds an `AppleAISession` from `agentNode.tools`, wrapping each `RTSAppleAIToolNode`
    /// in an `RTSAppleAIToolBridge` so tool calls are tracked as nodes via `RTSNodeInvoker`.
    /// Returns non-conforming tools separately so the caller can warn about them.
    static func build(
        fromAgentTools tools: [any RTSToolNode],
        invoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode
    ) -> (session: AppleAISession, unsupported: [any RTSToolNode]) {
        var appleTools: [any Tool] = []
        var unsupported: [any RTSToolNode] = []
        for tool in tools {
            if let appleTool = tool as? any RTSAppleAIToolNode {
                let bridge = appleTool.makeAppleAIBridge(invoker: invoker, createdBy: createdBy)
                          ?? (appleTool as any Tool)
                appleTools.append(bridge)
            } else {
                unsupported.append(tool)
            }
        }
        return (AppleAISession(tools: appleTools), unsupported)
    }

    private static func makeSession(instruction: String?, tools: [any Tool]) -> LanguageModelSession {
        switch (instruction, tools.isEmpty) {
        case (let inst?, false): return LanguageModelSession(tools: tools, instructions: inst)
        case (let inst?, true):  return LanguageModelSession(instructions: inst)
        case (nil, false):       return LanguageModelSession(tools: tools)
        case (nil, true):        return LanguageModelSession()
        }
    }
}

// MARK: - Transcript.Entry → RTSMessage

private extension Transcript.Entry {
    func toRTSMessage() -> RTSMessage? {
        let timestamp = Date()
        switch self {
        case .instructions(let instructions):
            return RTSMessage(
                id: UUID(),
                role: .system,
                content: .text(extractText(from: instructions)),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .prompt(let prompt):
            return RTSMessage(
                id: UUID(),
                role: .user,
                content: .text(extractText(from: prompt)),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .response(let response):
            return RTSMessage(
                id: UUID(),
                role: .assistant,
                content: .text(extractText(from: response)),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .toolCalls(let toolCalls):
            let text = Mirror(reflecting: toolCalls)
                .children.first(where: { $0.label == "calls" })
                .flatMap { $0.value as? [Any] }
                .map { calls in
                    calls.compactMap { call -> String? in
                        let m = Mirror(reflecting: call)
                        guard let name = m.children.first(where: { $0.label == "toolName" })?.value as? String,
                              let args = m.children.first(where: { $0.label == "rawArguments" })?.value as? String
                        else { return nil }
                        return "\(name): \(args)"
                    }.joined(separator: "\n")
                } ?? String(describing: toolCalls)
            return RTSMessage(
                id: UUID(),
                role: .assistant,
                content: .text(text),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        case .toolOutput(let toolOutput):
            let m = Mirror(reflecting: toolOutput)
            let toolName = m.children.first(where: { $0.label == "toolName" })?.value as? String ?? ""
            let text = "[\(toolName)] \(extractText(from: toolOutput))"
            return RTSMessage(
                id: UUID(),
                role: .tool,
                content: .text(text),
                timestamp: timestamp,
                metadata: nil,
                runID: nil
            )
        @unknown default:
            return nil
        }
    }
}

/// Extracts joined text from `segments[].text` via Mirror.
/// Falls back to `String(describing:)` if the expected structure is absent.
private func extractText(from value: Any) -> String {
    let m = Mirror(reflecting: value)
    guard let segsVal = m.children.first(where: { $0.label == "segments" })?.value else {
        return String(describing: value)
    }
    let texts = Mirror(reflecting: segsVal).children.compactMap { child -> String? in
        guard let textVal = Mirror(reflecting: child.value).children.first(where: { $0.label == "text" })?.value
        else { return nil }
        return String(describing: textVal)
    }
    return texts.isEmpty ? String(describing: value) : texts.joined(separator: " ")
}
