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
        // NOTE: if respond(to:) does not return String directly, use response.content
        return String(describing: response)
    }

    func messages() -> [RTSMessage] {
        lock.withLock { _messages }
    }

    /// Filters `agentNode.tools` to those conforming to `RTSAppleAIToolNode` and builds a session.
    /// Returns the non-conforming tools separately so the caller can warn about them.
    static func build(fromAgentTools tools: [any RTSToolNode]) -> (session: AppleAISession, unsupported: [any RTSToolNode]) {
        var appleTools: [any Tool] = []
        var unsupported: [any RTSToolNode] = []
        for tool in tools {
            if let appleTool = tool as? any RTSAppleAIToolNode {
                appleTools.append(appleTool as any Tool)
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
    // NOTE: adjust String(describing:) extractions if FoundationModels exposes typed text
    // accessors (e.g. instructions.text, response.content). Add tool cases once their
    // exact enum case names are confirmed from the FoundationModels API.
    func toRTSMessage() -> RTSMessage? {
        let timestamp = Date()
        switch self {
        case .instructions(let v):
            return RTSMessage(id: UUID(), role: .system,    content: .text(String(describing: v)), timestamp: timestamp, metadata: nil, runID: nil)
        case .prompt(let v):
            return RTSMessage(id: UUID(), role: .user,      content: .text(String(describing: v)), timestamp: timestamp, metadata: nil, runID: nil)
        case .response(let v):
            return RTSMessage(id: UUID(), role: .assistant, content: .text(String(describing: v)), timestamp: timestamp, metadata: nil, runID: nil)
        @unknown default:
            return nil
        }
    }
}
