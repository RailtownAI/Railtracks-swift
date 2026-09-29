//
//  KnowledgeToolTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-09-22.
//

import Foundation
import Synchronization
import Testing
@testable import RailtracksSwift

/// Records what the tool asked for, so the clamp can be asserted on the *request* rather than only
/// on what came back — the two differ, and only one of them is the behaviour under test.
private final class RecordingSource: RTSKnowledgeSource, @unchecked Sendable {

    private let received = Mutex<[RTSKnowledgeQuery]>([])
    private let hits: [RTSKnowledgeHit]
    private let failure: (any Error)?

    init(returning hits: [RTSKnowledgeHit] = [], failing failure: (any Error)? = nil) {
        self.hits = hits
        self.failure = failure
    }

    var lastQuery: RTSKnowledgeQuery? {
        received.withLock { $0.last }
    }

    func retrieve(_ query: RTSKnowledgeQuery) async throws -> [RTSKnowledgeHit] {
        received.withLock { $0.append(query) }
        if let failure {
            throw failure
        }
        return hits
    }
}

private struct StubFailure: Error {
}

extension RailtracksSwiftTestSuite {

    @Suite("Knowledge search tool")
    struct KnowledgeToolTests {

        private func makeTool(
            source: any RTSKnowledgeSource,
            range: ClosedRange<Int> = 1...5,
            minimumScore: Double? = nil
        ) -> RTSKnowledgeSearchTool {
            RTSKnowledgeSearchTool(
                toolName: "SearchDocs",
                toolDescription: "Search the docs.",
                source: source,
                resultCountRange: range,
                minimumScore: minimumScore
            )
        }

        private func results(in output: RTSOutput) -> [RTSValue] {
            guard case .array(let results)? = output["results"] else {
                return []
            }
            return results
        }

        private func field(_ name: String, of value: RTSValue) -> RTSValue? {
            guard case .object(let fields) = value else {
                return nil
            }
            return fields[name]
        }

        // MARK: - Schema

        @Test("the schema declares both parameters and names the bounds")
        func schemaDeclaresParameters() {
            let tool = makeTool(source: RecordingSource(), range: 2...8)
            let parameters = tool.parameterSchema.parameters

            #expect(parameters.map { $0.name } == ["query", "topK"])
            // The bounds go in the description because the schema cannot express them: a model
            // that is not told the ceiling will ask for twenty.
            let topK = try? #require(parameters.first { $0.name == "topK" })
            #expect(topK?.description.contains("2") == true)
            #expect(topK?.description.contains("8") == true)
        }

        // MARK: - Mapping

        @Test("a hit round-trips into the output with its citation intact")
        func hitRoundTrips() async throws {
            let source = RecordingSource(returning: [
                RTSKnowledgeHit(
                    content: "Refunds take thirty days.",
                    source: "file:///policies.txt",
                    score: 0.82,
                    metadata: ["page": .number(4), "section": .string("Returns")]
                )
            ])

            let output = try await makeTool(source: source).run(with: [
                "query": .string("refunds"),
                "topK": .number(1),
            ])
            let hit = try #require(results(in: output).first)

            // `source` and `metadata` are the whole reason this type is richer than a string: an
            // agent asked "where did that come from?" answers from these.
            #expect(field("content", of: hit) == .string("Refunds take thirty days."))
            #expect(field("source", of: hit) == .string("file:///policies.txt"))
            #expect(field("score", of: hit) == .number(0.82))
            #expect(field("metadata", of: hit) == .object(["page": .number(4), "section": .string("Returns")]))
        }

        @Test("a hit with no source omits the key rather than sending null")
        func absentSourceIsOmitted() async throws {
            let source = RecordingSource(returning: [RTSKnowledgeHit(content: "text")])

            let output = try await makeTool(source: source).run(with: [
                "query": .string("q"),
                "topK": .number(1),
            ])
            let hit = try #require(results(in: output).first)

            // A model reading `"source": null` tends to remark on the absence, which is noise.
            #expect(field("source", of: hit) == nil)
            #expect(field("metadata", of: hit) == nil)
        }

        // MARK: - The clamp

        @Test("a count above the range is clamped before the source is asked", arguments: [
            (requested: 50.0, expected: 5),
            (requested: 0.0, expected: 1),
            (requested: 3.0, expected: 3),
        ])
        func countIsClamped(requested: Double, expected: Int) async throws {
            let source = RecordingSource()

            _ = try await makeTool(source: source).run(with: [
                "query": .string("q"),
                "topK": .number(requested),
            ])

            // Asserted on what the *source received*. Clamping only the returned array would still
            // have paid for the oversized retrieval.
            #expect(source.lastQuery?.topK == expected)
        }

        @Test("a missing count falls back to the lower bound")
        func missingCountFallsBack() async throws {
            let source = RecordingSource()

            _ = try await makeTool(source: source, range: 2...8).run(with: ["query": .string("q")])

            // Defensive only — the parameter is required, so this is a malformed call.
            #expect(source.lastQuery?.topK == 2)
        }

        @Test("an over-returning source is truncated")
        func overReturningSourceIsTruncated() async throws {
            let source = RecordingSource(
                returning: (0..<50).map { RTSKnowledgeHit(content: "chunk \($0)", score: 0.9) }
            )

            let output = try await makeTool(source: source).run(with: [
                "query": .string("q"),
                "topK": .number(5),
            ])

            // A custom source is under no obligation to honour `topK`, and each hit is chunk-sized
            // — fifty of them would be tens of kilobytes of prompt nobody asked for.
            #expect(results(in: output).count == 5)
        }

        // MARK: - Relevance

        @Test("hits below the minimum score are dropped")
        func minimumScoreFilters() async throws {
            let source = RecordingSource(returning: [
                RTSKnowledgeHit(content: "close", score: 0.8),
                RTSKnowledgeHit(content: "far", score: 0.2),
            ])

            let output = try await makeTool(source: source, minimumScore: 0.5).run(with: [
                "query": .string("q"),
                "topK": .number(5),
            ])
            let contents = results(in: output).compactMap { field("content", of: $0) }

            #expect(contents == [.string("close")])
        }

        @Test("nothing relevant yields an empty array, not an error")
        func nothingRelevantIsEmpty() async throws {
            let source = RecordingSource(returning: [RTSKnowledgeHit(content: "far", score: 0.1)])

            let output = try await makeTool(source: source, minimumScore: 0.5).run(with: [
                "query": .string("q"),
                "topK": .number(5),
            ])

            // The only way "no good match" is expressible: a store has no relevance floor of its
            // own and answers every question with its top matches, however far-fetched.
            #expect(results(in: output).isEmpty)
        }

        @Test("filtering happens before truncation")
        func filterPrecedesTruncation() async throws {
            var hits = (0..<5).map { RTSKnowledgeHit(content: "noise \($0)", score: 0.1) }
            hits.append(RTSKnowledgeHit(content: "signal", score: 0.9))
            let source = RecordingSource(returning: hits)

            let output = try await makeTool(source: source, minimumScore: 0.5).run(with: [
                "query": .string("q"),
                "topK": .number(5),
            ])
            let contents = results(in: output).compactMap { field("content", of: $0) }

            // Truncating first would take the five low scorers and drop the one good hit — the
            // source is not required to return anything in score order.
            #expect(contents == [.string("signal")])
        }

        // MARK: - Failure

        @Test("a failing source propagates rather than reading as no matches")
        func failureIsNotSilence() async throws {
            let source = RecordingSource(failing: StubFailure())
            let tool = makeTool(source: source)

            await #expect(throws: StubFailure.self) {
                _ = try await tool.run(with: ["query": .string("q"), "topK": .number(1)])
            }
        }

        @Test("a missing query is a missing input, not an empty search")
        func missingQueryThrows() async throws {
            let tool = makeTool(source: RecordingSource())

            await #expect(throws: RTSError.self) {
                _ = try await tool.run(with: ["topK": .number(1)])
            }
        }

        // MARK: - On-device conformance

        @Test("on OS 26 the same tool is an Apple on-device tool")
        func isAnAppleAIToolNode() throws {
            guard #available(macOS 26, iOS 26, *) else {
                return
            }
            let tool: any RTSToolNode = makeTool(source: RecordingSource())

            // The dynamic cast the Apple path makes. Without the conformance it fails and the
            // tool is dropped with a warning, leaving an on-device agent with no search.
            #expect(tool is any RTSAppleAIToolNode)
        }

        @Test("on-device arguments are named as the routine reads them")
        func argumentsMatchTheInputKeys() throws {
            guard #available(macOS 26, iOS 26, *) else {
                return
            }
            let schema = RTSKnowledgeSearchTool.Arguments.generationSchema
            let encoded = try JSONEncoder().encode(schema)
            let decoded = try JSONSerialization.jsonObject(with: encoded)
            let json = try #require(decoded as? [String: Any])
            let properties = try #require(json["properties"] as? [String: Any])
            let expected: Set = [RTSKnowledgeSearchTool.queryKey, RTSKnowledgeSearchTool.topKKey]

            // `call(arguments:)` round-trips these through JSON into the `RTSInput` the search
            // closure reads, so a renamed property would arrive as a missing input.
            #expect(Set(properties.keys) == expected)
        }

        @Test("an on-device call runs the same routine and returns its results")
        func onDeviceCallRunsTheRoutine() async throws {
            guard #available(macOS 26, iOS 26, *) else {
                return
            }
            let hit = RTSKnowledgeHit(
                content: "Refunds take thirty days.",
                source: "policies.pdf#page-4",
                score: 0.8
            )
            let source = RecordingSource(returning: [hit])
            let tool = makeTool(source: source, range: 1...3)

            let output = try await tool.call(arguments: .init(query: "refunds", topK: 9))

            // One routine for every provider: the clamp and the encoding are the cloud path's.
            #expect(source.lastQuery?.text == "refunds")
            #expect(source.lastQuery?.topK == 3)
            #expect(output.contains("Refunds take thirty days."))
            #expect(output.contains("policies.pdf#page-4"))
        }

        // MARK: - Through the invoker

        @Test("the tool runs through the node invoker and publishes events")
        func runsThroughTheInvoker() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let source = RecordingSource(returning: [RTSKnowledgeHit(content: "found", score: 0.9)])
            let tool = makeTool(source: source)
            let invoker = RTSNodeInvoker(stampFactory: RTSStampFactory(), sessionID: UUID())
            let input: RTSInput = ["query": .string("refunds"), "topK": .number(1)]

            let output = try await invoker.invokeTool(tool, input: input)

            // Covers the path a real agent takes — the invoker decodes `RTSInput` and stamps
            // node/edge events — rather than only the closure the other cases call directly.
            #expect(results(in: output).count == 1)
            #expect(source.lastQuery?.text == "refunds")
        }
    }
}
