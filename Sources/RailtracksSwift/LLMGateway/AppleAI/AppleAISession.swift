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

final class AppleAISession: @unchecked Sendable {
    private var session: LanguageModelSession
    private let sessionTools: [any Tool]
    private let outputSchema: GenerationSchema?
    private var _messages: [RTSMessage] = []
    private let lock = NSLock()

    private init(tools: [any Tool] = [], outputSchema: GenerationSchema? = nil) {
        self.sessionTools = tools
        self.outputSchema = outputSchema
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

    func send(_ prompt: String) async throws -> AppleAIResponse {
        let currentSession = lock.withLock { session }
        let beforeCount = currentSession.transcript.count
        let responseText: String
        let metrics: AppleAIResponse
        if let schema = outputSchema {
            let response = try await currentSession.respond(to: prompt, schema: schema)
            responseText = generatedContentToJSONString(response.content) ?? String(describing: response.content)
            metrics = extractResponseMetrics(from: response, text: responseText)
        } else {
            let response = try await currentSession.respond(to: prompt)
            responseText = response.content
            metrics = extractResponseMetrics(from: response, text: responseText)
        }
        let newMessages = currentSession.transcript.dropFirst(beforeCount).compactMap { $0.toRTSMessage() }
        let rawCount = currentSession.transcript.count - beforeCount
        log.debug("🍎 send: \(rawCount) new transcript entries, \(newMessages.count) converted to RTSMessage")
        lock.withLock {
            _messages.append(contentsOf: newMessages)
        }
        return metrics
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
    static func build(
        fromAgentTools tools: [any RTSToolNode],
        invoker: RTSNodeInvoker,
        createdBy: any RTSAgentNode,
        makeSubSession: @escaping @Sendable (any RTSAgentNode) throws -> RTSLLMSession,
        onNewSession: @escaping @Sendable (RTSLLMSession) -> Void
    ) -> (session: AppleAISession, unsupported: [any RTSToolNode]) {
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
                    log.warning("⚠️🍎 [\(createdBy.agentName)] RTSAgentTool '\(agentTool.toolName)' schema conversion failed, tool dropped: \(error)")
                    unsupportedTools.append(tool)
                }
            } else if let appleTool = tool as? any RTSAppleAIToolNode {
                let bridge = appleTool.makeAppleAIBridge(invoker: invoker, createdBy: createdBy)
                          ?? (appleTool as any Tool)
                appleTools.append(bridge)
            } else {
                unsupportedTools.append(tool)
            }
        }
        let schema: GenerationSchema?
        if let rtsSchema = createdBy.outputSchema {
            do {
                schema = try rtsSchema.toFoundationModelsSchema()
            } catch {
                log.warning("⚠️🍎 [\(createdBy.agentName)] outputSchema conversion failed, running without structured output: \(error)")
                schema = nil
            }
        } else {
            schema = nil
        }
        return (AppleAISession(tools: appleTools, outputSchema: schema), unsupportedTools)
    }

    private static func makeSession(instruction: String?, tools: [any Tool]) -> LanguageModelSession {
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

// MARK: - GeneratedContent → JSON String

private extension AppleAISession {
    /// Serializes a `GeneratedContent` structured response to a JSON string.
    /// Uses Mirror reflection on Apple's internal `GeneratedJSON.Storage` enum — the same
    /// approach as `extractText` and `extractParameters` elsewhere in this file.
    func generatedContentToJSONString(_ content: GeneratedContent) -> String? {
        guard let anyValue = extractAny(from: content) else { return nil }
        guard JSONSerialization.isValidJSONObject(anyValue) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func extractAny(from content: GeneratedContent) -> Any? {
        let m = Mirror(reflecting: content)
        guard let jsonVal = m.children.first(where: { $0.label == "value" })?.value else { return nil }
        return extractAnyFromJSON(jsonVal)
    }

    private func extractAnyFromJSON(_ json: Any) -> Any? {
        let m = Mirror(reflecting: json)
        guard let storage = m.children.first(where: { $0.label == "storage" })?.value else { return nil }
        return extractAnyFromStorage(storage)
    }

    private func extractAnyFromStorage(_ storage: Any) -> Any? {
        let m = Mirror(reflecting: storage)
        guard let child = m.children.first else { return NSNull() }
        switch child.label {
        case "string": return child.value as? String
        case "number": return child.value as? Double
        case "bool":   return child.value as? Bool
        case "null":   return NSNull()
        case "array":
            return Mirror(reflecting: child.value).children.map { extractAnyFromJSON($0.value) as Any }
        case "object":
            // The associated value is an internal struct with `order: [String]` and
            // `properties: [String: GeneratedJSON]` — not a flat dictionary.
            let objMirror = Mirror(reflecting: child.value)
            guard let propertiesAny = objMirror.children.first(where: { $0.label == "properties" })?.value else {
                return [String: Any]()
            }
            var dict: [String: Any] = [:]
            for entry in Mirror(reflecting: propertiesAny).children {
                // Each entry is a (key: String, value: GeneratedJSON) Dictionary element
                let pair = Mirror(reflecting: entry.value)
                if let key = pair.children.first(where: { $0.label == "key" })?.value as? String,
                   let val = pair.children.first(where: { $0.label == "value" })?.value {
                    dict[key] = extractAnyFromJSON(val) as Any
                }
            }
            return dict
        default:
            log.warning("⚠️🍎 Unknown GeneratedJSON storage case '\(child.label as Any)' in structured output")
            return String(describing: child.value)
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
            log.debug("🍎 toRTSMessage: unhandled Transcript.Entry case: \(self)")
            return nil
        }
    }
}

/// Extracts joined text from `segments[].text` via Mirror.
/// Falls back to `String(describing:)` if the expected structure is absent.
///
/// This is targeted specifically against how Transcript.Entry is currently structured.
/// Will need to be updated if Transcript.Entry changes.
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
