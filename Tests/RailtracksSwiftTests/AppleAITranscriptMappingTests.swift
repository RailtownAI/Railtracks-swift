//
//  AppleAITranscriptMappingTests.swift
//  RailtracksSwiftTests
//
//  The FoundationModels path reads transcript entries, structured output and `@Generable` tool
//  schemas through Apple's public API. These tests pin what each conversion produces — the values
//  were first captured from the Mirror-based code they replaced, so any difference below is a
//  deliberate one, called out where it occurs. See docs/foundation-models-provider.md.
//

import Testing
import Foundation
import Combine
@testable import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)

/// An AppleAI tool whose `Arguments` cover every parameter type `RTSValueType` can express.
@available(macOS 26, iOS 26, *)
private struct EveryTypeAppleAITool: RTSAppleAIToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName = "every_type"
    let toolDescription = "stub AppleAI tool"
    let callableRoutine = RTSClosure { _ in [:] }

    @Generable
    struct Arguments: Encodable {
        @Guide(description: "A name.")
        var name: String
        @Guide(description: "A count.")
        var count: Int
        @Guide(description: "A ratio.")
        var ratio: Double
        @Guide(description: "A flag.")
        var flag: Bool
        @Guide(description: "Some tags.")
        var tags: [String]
        @Guide(description: "Some scores.")
        var scores: [Int]
        var undocumented: String
    }

    typealias Output = String
}

/// A working addition tool, so a live run can take a tool-call turn.
@available(macOS 26, iOS 26, *)
private struct AdditionAppleAITool: RTSAppleAIToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName = "Addition"
    let toolDescription = "Adds two numbers and returns the result."
    let callableRoutine = RTSClosure { inputs in
        guard case let .number(left) = inputs["a"], case let .number(right) = inputs["b"] else {
            throw RTSError.missingInput("a, b")
        }
        return ["result": .number(left + right)]
    }

    @Generable
    struct Arguments: Encodable {
        @Guide(description: "First number to add")
        var a: Double
        @Guide(description: "Second number to add")
        var b: Double
    }

    typealias Output = String
}

@Suite("AppleAI transcript mapping")
struct AppleAITranscriptMappingTests {

    // MARK: - Transcript.Entry → RTSMessage

    @Test("Text entries keep their role and join segments with a space")
    func textEntries() throws {
        guard #available(macOS 26, iOS 26, *) else {
            return
        }
        let instructions = Transcript.Entry.instructions(
            Transcript.Instructions(segments: [.text(.init(content: "Be brief"))], toolDefinitions: [])
        )
        let prompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(.init(content: "hi")), .text(.init(content: "there"))])
        )
        let response = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.text(.init(content: "hello"))])
        )

        let systemMessage = try #require(instructions.toRTSMessage())
        #expect(systemMessage.role == .system)
        #expect(systemMessage.content.textValue == "Be brief")

        let userMessage = try #require(prompt.toRTSMessage())
        #expect(userMessage.role == .user)
        #expect(userMessage.content.textValue == "hi there")

        let assistantMessage = try #require(response.toRTSMessage())
        #expect(assistantMessage.role == .assistant)
        #expect(assistantMessage.content.textValue == "hello")
    }

    /// A deliberate change: the Mirror code found no `text` field on a structured segment and fell
    /// back to describing the whole entry, producing `(Response) {"b": 2, "a": "x"}`.
    @Test("A structured response segment becomes its JSON, without the entry's description")
    func structuredResponse() throws {
        guard #available(macOS 26, iOS 26, *) else {
            return
        }
        let content = GeneratedContent(properties: ["b": 2, "a": "x"])
        let response = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.structure(.init(source: "Answer", content: content))])
        )

        let message = try #require(response.toRTSMessage())
        #expect(message.content.textValue == #"{"b": 2, "a": "x"}"#)
    }

    @Test("Tool calls become one `name: arguments` line per call")
    func toolCalls() throws {
        guard #available(macOS 26, iOS 26, *) else {
            return
        }
        let toolCalls = Transcript.Entry.toolCalls(
            Transcript.ToolCalls([
                Transcript.ToolCall(id: "1", toolName: "add", arguments: GeneratedContent(properties: ["b": 2, "a": "x"])),
                Transcript.ToolCall(id: "2", toolName: "sub", arguments: GeneratedContent(properties: ["n": 1])),
            ])
        )

        let message = try #require(toolCalls.toRTSMessage())
        #expect(message.role == .assistant)
        #expect(message.content.textValue == "add: {\"b\": 2, \"a\": \"x\"}\nsub: {\"n\": 1}")
    }

    @Test("Tool output is prefixed with its tool name")
    func toolOutput() throws {
        guard #available(macOS 26, iOS 26, *) else {
            return
        }
        let toolOutput = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(id: "1", toolName: "add", segments: [.text(.init(content: "3"))])
        )

        let message = try #require(toolOutput.toRTSMessage())
        #expect(message.role == .tool)
        #expect(message.content.textValue == "[add] 3")
    }

    /// Reasoning is not a message: as one it would count as an extra round trip in `llm_details`.
    @Test("A reasoning entry is not turned into a message")
    func reasoningIsSkipped() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let reasoning = Transcript.Entry.reasoning(
            Transcript.Reasoning(segments: [.text(.init(content: "thinking…"))])
        )

        #expect(reasoning.toRTSMessage() == nil)
    }

    // MARK: - Structured output

    /// `jsonString` keeps declaration order; the Mirror code produced the same values through
    /// `JSONSerialization`, in dictionary order. Compared as parsed JSON, so order is not asserted.
    @Test("Structured output serializes nested values to valid JSON")
    func structuredOutputJSON() throws {
        guard #available(macOS 26, iOS 26, *) else {
            return
        }
        let content = GeneratedContent(properties: [
            "s": "x",
            "n": 1.5,
            "b": true,
            "list": [1, 2],
            "obj": GeneratedContent(properties: ["k": "v"]),
        ])

        let parsed = try JSONSerialization.jsonObject(with: Data(content.jsonString.utf8))
        let object = try #require(parsed as? NSDictionary)
        let expected: NSDictionary = [
            "s": "x",
            "n": 1.5,
            "b": true,
            "list": [1, 2],
            "obj": ["k": "v"],
        ]
        #expect(object == expected)
    }

    // MARK: - @Generable → tool parameters

    /// The Mirror walk over `GenerationSchema` returned `[]` on OS 27 — Apple's internal field
    /// names had changed — so on that OS this is a fix, not only a refactor.
    @Test("Tool parameters come from the @Generable schema, in declaration order")
    func toolParameters() {
        guard #available(macOS 26, iOS 26, *) else {
            return
        }
        let parameters = EveryTypeAppleAITool().parameterSchema.parameters

        #expect(parameters.map(\.name) == ["name", "count", "ratio", "flag", "tags", "scores", "undocumented"])
        // `RTSValueType` is not `Equatable`; its description is exact enough to compare.
        #expect(
            parameters.map { String(describing: $0.type) }
                == [
                    "string",
                    "number",
                    "number",
                    "bool",
                    "array(RailtracksSwift.RTSValueType.string)",
                    "array(RailtracksSwift.RTSValueType.number)",
                    "string",
                ]
        )
        #expect(parameters.map(\.description) == ["A name.", "A count.", "A ratio.", "A flag.", "Some tags.", "Some scores.", ""])
    }
}

// MARK: - .foundationModel provider

@Suite("FoundationModels provider")
struct FoundationModelProviderTests {

    @Test("A wrapped model reports its kind and model id as its own")
    func reportsWrappedIdentity() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let languageModel = RTSFoundationLanguageModel(
            SystemLanguageModel.default,
            kind: .anthropic,
            modelID: "claude-sonnet-4-6"
        )
        let provider = RTSLLMProvider.foundationModel(languageModel)

        #expect(provider.kind == .anthropic)
        #expect(provider.providerName == "Anthropic")
        #expect(provider.modelID == "claude-sonnet-4-6")
        #expect(provider.isLocal == false)
        #expect(provider.description == "FoundationModels-Anthropic-claude-sonnet-4-6")
    }

    @Test("A wrapped on-device model is local, so it is not priced")
    func onDeviceIsLocal() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let languageModel = RTSFoundationLanguageModel(
            SystemLanguageModel.default,
            kind: .appleAI,
            modelID: "on-device"
        )

        #expect(RTSLLMProvider.foundationModel(languageModel).isLocal)
    }

    /// Live: needs the on-device model. Checks the OS 27 usage read end to end — that token counts
    /// arrive and land on the final assistant message only, while every assistant message, tool-call
    /// turns included, is still labelled with its model and provider.
    ///
    /// The tool makes tool-call turns likely but not certain — the model decides — so the
    /// earlier-message assertions hold vacuously on a run that answers directly.
    @Test("A run reports token usage on its final assistant message")
    func runReportsUsage() async throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        guard case .available = SystemLanguageModel.default.availability else {
            print("⏭️ on-device model unavailable; skipping live usage check")
            return
        }
        let languageModel = RTSFoundationLanguageModel(
            SystemLanguageModel.default,
            kind: .appleAI,
            modelID: "on-device"
        )
        let agent = RTSAgent(
            llmProvider: .foundationModel(languageModel),
            name: "Usage Probe",
            tools: [AdditionAppleAITool()],
            systemMessage: "You must use the addition tool for any addition."
        )
        let gateway = RTSLLMGateway(apiKeys: [:])
        let invoker = RTSNodeInvoker(stampFactory: RTSStampFactory(), sessionID: UUID())
        let session = try gateway.session(invoker: invoker, agentNode: agent, onNewSession: { _ in })

        let published = PublishedMessages()
        let subscription = session.messagePublisher.sink { messages in
            published.append(messages)
        }
        defer {
            subscription.cancel()
        }
        _ = try await session.run("What is 2 + 3? Reply with just the number.", runID: UUID())

        let assistantMessages = published.messages.filter { $0.role == .assistant }
        let finalMessage = try #require(assistantMessages.last)
        #expect((finalMessage.metadata?.inputTokenCount ?? 0) > 0)
        #expect((finalMessage.metadata?.tokenCount ?? 0) > 0)
        #expect(finalMessage.metadata?.model == "on-device")
        #expect(finalMessage.metadata?.providerName == "AppleAI")
        print("ℹ️ live usage run produced \(assistantMessages.count) assistant message(s)")
        for earlier in assistantMessages.dropLast() {
            #expect(earlier.metadata?.model == "on-device")
            #expect(earlier.metadata?.providerName == "AppleAI")
            #expect(earlier.metadata?.inputTokenCount == nil)
            #expect(earlier.metadata?.tokenCount == nil)
        }
    }
}

// MARK: - One model call, one message

@Suite("FoundationModels assistant-message merging")
struct AssistantMessageMergingTests {

    private func message(_ role: RTSMessage.Role, _ text: String) -> RTSMessage {
        RTSMessage(
            id: UUID(),
            role: role,
            content: .text(text),
            timestamp: Date(),
            metadata: nil,
            runID: nil
        )
    }

    /// The shape of a live Claude run: each tool call is preceded by narration from the same model
    /// call, which the transcript records as a separate `.response` entry.
    @Test("Narration and the tool call beside it become one assistant message")
    func narrationMergesWithToolCall() {
        let merged = mergingConsecutiveAssistantMessages([
            message(.user, "What is 50 + 20 x 8 - 4?"),
            message(.assistant, "Step 1: 20 x 8"),
            message(.assistant, #"Multiplication: {"b": 8, "a": 20}"#),
            message(.tool, "[Multiplication] 160"),
            message(.assistant, "Step 2: 50 + 160"),
            message(.assistant, #"Addition: {"b": 160, "a": 50}"#),
            message(.tool, "[Addition] 210"),
            message(.assistant, "206"),
        ])

        #expect(merged.map(\.role) == [.user, .assistant, .tool, .assistant, .tool, .assistant])
        #expect(merged[1].content.textValue == "Step 1: 20 x 8\nMultiplication: {\"b\": 8, \"a\": 20}")
        #expect(merged[5].content.textValue == "206")
    }

    @Test("Assistant messages separated by a tool result stay separate")
    func toolResultSeparatesCalls() {
        let messages = [
            message(.assistant, "Addition: {}"),
            message(.tool, "[Addition] 3"),
            message(.assistant, "3"),
        ]

        #expect(mergingConsecutiveAssistantMessages(messages).count == 3)
    }
}

// MARK: - Stamping one respond's messages

@Suite("FoundationModels message stamping")
struct FoundationModelsMessageStampingTests {

    /// One `respond` with a tool-call turn: prompt, tool call, tool output, final answer.
    private func toolCallingTurn() -> [RTSMessage] {
        [RTSMessage.Role.user, .assistant, .tool, .assistant].map { role in
            RTSMessage(
                id: UUID(),
                role: role,
                content: .text("\(role)"),
                timestamp: Date(),
                metadata: nil,
                runID: nil
            )
        }
    }

    @Test("Usage lands on the final assistant message; every assistant message keeps its labels")
    func usageOnFinalLabelsOnAll() throws {
        let runID = UUID()
        let response = AppleAIResponse(text: "5", inputTokens: 120, outputTokens: 7, latency: 0.5)

        let stamped = stampFoundationModelsMessages(
            toolCallingTurn(),
            runID: runID,
            response: response,
            model: "on-device",
            providerName: "AppleAI"
        )

        #expect(stamped.allSatisfy { $0.runID == runID })

        let toolCallTurn = try #require(stamped[1].metadata)
        #expect(toolCallTurn.model == "on-device")
        #expect(toolCallTurn.providerName == "AppleAI")
        #expect(toolCallTurn.inputTokenCount == nil)
        #expect(toolCallTurn.tokenCount == nil)
        #expect(toolCallTurn.generationTime == nil)

        let finalTurn = try #require(stamped[3].metadata)
        #expect(finalTurn.model == "on-device")
        #expect(finalTurn.providerName == "AppleAI")
        #expect(finalTurn.inputTokenCount == 120)
        #expect(finalTurn.tokenCount == 7)
        #expect(finalTurn.generationTime == 0.5)

        #expect(stamped[0].metadata == nil)
        #expect(stamped[2].metadata == nil)
    }

    @Test("A failed respond still labels its assistant messages, with no usage")
    func failedRespondLabelsWithoutUsage() throws {
        let stamped = stampFoundationModelsMessages(
            toolCallingTurn(),
            runID: UUID(),
            response: nil,
            model: "claude-sonnet-4-6",
            providerName: "Anthropic"
        )

        for message in stamped where message.role == .assistant {
            let metadata = try #require(message.metadata)
            #expect(metadata.model == "claude-sonnet-4-6")
            #expect(metadata.providerName == "Anthropic")
            #expect(metadata.inputTokenCount == nil)
        }
    }
}

private final class PublishedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RTSMessage] = []

    func append(_ messages: [RTSMessage]) {
        lock.withLock {
            stored.append(contentsOf: messages)
        }
    }

    var messages: [RTSMessage] {
        lock.withLock {
            stored
        }
    }
}

#endif
