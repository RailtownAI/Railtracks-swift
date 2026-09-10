//
//  LLMDetailsParityTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-09-08.
//

import Foundation
import Testing
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {

    /// Guards the flow-graph JSON against the `RTSLLMRoundTrip` extraction.
    ///
    /// `makeLLMDetails`' round-trip walk is now shared with the `llm.*` events, and the two
    /// streams apply different defaults to the same optional fields — the flow graph
    /// substitutes `0` / `"unknown"`, the event stream writes `null`. Nothing else in the
    /// suite covers this: the other trace tests drive orchestrator stubs with no LLM, so they
    /// never produce an assistant message and `llm_details` stays nil.
    @Suite("LLM details parity")
    struct LLMDetailsParityTests {

        private static let stamp = Date(timeIntervalSince1970: 1_788_000_000)

        private func message(
            _ role: RTSMessage.Role,
            _ text: String,
            metadata: RTSMessageMetadata? = nil
        ) -> RTSMessage {
            RTSMessage(
                id: UUID(),
                role: role,
                content: .text(text),
                timestamp: Self.stamp,
                metadata: metadata,
                runID: nil
            )
        }

        private func metadata(
            model: String?,
            provider: String?,
            inputTokens: Int?,
            outputTokens: Int?,
            latency: TimeInterval?,
            fingerprint: String? = nil
        ) -> RTSMessageMetadata {
            RTSMessageMetadata(
                tokenCount: outputTokens,
                inputTokenCount: inputTokens,
                generationTime: latency,
                model: model,
                providerName: provider,
                tokensPerSecond: nil,
                providerExtra: fingerprint.map { ["system_fingerprint": $0] },
                custom: nil,
                toolCalls: nil
            )
        }

        /// Builds the graph through the real parser and returns the root node's `llm_details`.
        private func llmDetails(
            for messages: [RTSMessage]
        ) async throws -> [RTSFlowGraphLLMDetail] {
            let nodeID = UUID()
            let stampFactory = RTSStampFactory()
            let create = RTSNodeEvent(
                nodeID: nodeID,
                name: "Agent",
                nodeType: .agent,
                stamp: await stampFactory.makeStamp(event: .startCreate("Agent"))
            )
            let finish = RTSNodeEvent(
                nodeID: nodeID,
                name: "Agent",
                nodeType: .agent,
                stamp: await stampFactory.makeStamp(event: .finishExecution("Agent")),
                runID: UUID(),
                messages: messages
            )
            let graph = await RTSFlowGraph.make(
                flowName: "Parity",
                sessionID: UUID(),
                nodeEvents: [create, finish],
                edgeEvents: [],
                rootNodeID: nodeID,
                startTime: 0,
                endTime: 1
            )
            let node = try #require(graph.runs.first?.nodes.first)
            return try #require(node.details.internals.llmDetails)
        }

        // MARK: - Defaults

        @Test("A fully-populated assistant message maps every field through")
        func populatedMessage() async throws {
            let details = try await llmDetails(for: [
                message(.user, "hi"),
                message(
                    .assistant,
                    "hello",
                    metadata: metadata(
                        model: "gpt-4o",
                        provider: "OpenAI",
                        inputTokens: 12,
                        outputTokens: 3,
                        latency: 1.5,
                        fingerprint: "fp_1"
                    )
                ),
            ])

            #expect(details.count == 1)
            let detail = try #require(details.first)
            #expect(detail.modelName == "gpt-4o")
            #expect(detail.modelProvider == "OpenAI")
            #expect(detail.inputTokens == 12)
            #expect(detail.outputTokens == 3)
            #expect(detail.latency == 1.5)
            #expect(detail.systemFingerprint == "fp_1")
            // Input is every message before the assistant one.
            #expect(detail.input.count == 1)
            #expect(detail.input.first?.role == "user")
            #expect(detail.output.role == "assistant")
        }

        @Test("Absent metadata still yields the flow graph's own defaults, not nulls")
        func absentMetadataKeepsFlowGraphDefaults() async throws {
            // The load-bearing case for the extraction: `RTSLLMRoundTrip` holds these as
            // optionals so the event stream can write null, and the flow graph has to keep
            // substituting its own values on the way out.
            let details = try await llmDetails(for: [
                message(.assistant, "hello", metadata: nil),
            ])

            let detail = try #require(details.first)
            #expect(detail.modelName == "unknown")
            #expect(detail.modelProvider == "unknown")
            #expect(detail.inputTokens == 0)
            #expect(detail.outputTokens == 0)
            #expect(detail.latency == 0)
            #expect(detail.systemFingerprint == nil)
            #expect(detail.totalCost == nil)
        }

        @Test("A local provider is not priced")
        func localProviderIsNotPriced() async throws {
            let details = try await llmDetails(for: [
                message(
                    .assistant,
                    "hello",
                    metadata: metadata(
                        model: "apple-fm",
                        provider: RTSLLMProvider.appleAI.providerName,
                        inputTokens: 5,
                        outputTokens: 2,
                        latency: 0.1
                    )
                ),
            ])

            #expect(try #require(details.first).totalCost == nil)
        }

        // MARK: - Shape

        @Test("One detail per assistant message, each seeing everything before it")
        func onePerAssistantMessage() async throws {
            // The tool-calling shape: assistant asks for a tool, tool answers, assistant
            // concludes. Two round trips, and the second sees all three earlier messages.
            let details = try await llmDetails(for: [
                message(.user, "hi"),
                message(.assistant, "calling a tool"),
                message(.tool, "tool result"),
                message(.assistant, "final answer"),
            ])

            #expect(details.count == 2)
            #expect(details[0].input.count == 1)
            #expect(details[1].input.count == 3)
        }

        @Test("A log with no assistant message yields no details")
        func noAssistantMessages() async throws {
            let details = try await llmDetails(for: [
                message(.user, "hi"),
                message(.system, "be nice"),
            ])

            #expect(details.isEmpty)
        }
    }
}
