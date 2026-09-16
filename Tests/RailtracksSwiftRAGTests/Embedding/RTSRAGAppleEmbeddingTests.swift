//
//  RTSRAGAppleEmbeddingTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// The on-device embedder, which needs no key, no network and no spend — which is why it lands
/// first and why these tests can assert on real vectors rather than on a mock's return value.
@Suite("RailtracksSwiftRAG Apple embedding")
struct RTSRAGAppleEmbeddingTests {

    private static func makeEmbedder() throws -> RTSRAGAppleEmbedding {
        let embedder = try RTSRAGAppleEmbedding()
        return embedder
    }

    // MARK: - Identity

    @Test("the identifier names everything that defines the vector space")
    func identifierCarriesRevisionAndPooling() throws {
        let embedder = try Self.makeEmbedder()

        // A friendly name would let a store built under a different revision or pooling pass the
        // mismatch guard — and both produce incomparable vectors from identical weights, scoring
        // plausibly while ranking meaninglessly.
        #expect(embedder.modelIdentifier.hasPrefix("nl-contextual/"))
        #expect(embedder.modelIdentifier.contains("/rev"))
        #expect(embedder.modelIdentifier.hasSuffix("/mean"))
        #expect(embedder.embeddingVersion?.hasPrefix("rev") == true)
    }

    @Test("an absent revision fails at construction rather than resolving something else")
    func absentRevisionFailsLoudly() {
        // The reason the revision is pinned at all. `NLContextualEmbedding(language:)` resolves
        // "most recent", so two devices on different OS versions would silently embed into
        // different spaces and compare across them. Failing here is the loud, correct outcome;
        // the alternative is confidently wrong rankings at query time.
        #expect(throws: RTSRAGError.self) {
            _ = try RTSRAGAppleEmbedding(revision: 99)
        }
    }

    // MARK: - Vectors

    @Test("the same text embeds to the same vector")
    func embeddingIsDeterministic() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()

        let first = try await embedder.embed(["The refund policy is thirty days."])
        let second = try await embedder.embed(["The refund policy is thirty days."])

        // Determinism is what makes an embedding cacheable and a store re-checkable. It is also
        // the clearest practical difference from a generative model: no sampling, no temperature.
        #expect(first.vectors == second.vectors)
        #expect(first.vectors.first?.count == 512)
    }

    @Test("related text scores higher than unrelated text")
    func vectorsCarryMeaning() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()

        let result = try await embedder.embed([
            "The refund policy allows returns within thirty days.",
            "Customers may send items back for money within a month.",
            "Tomorrow will be cloudy with a chance of rain.",
        ])

        // The one property no mock can establish: that the numbers mean something. Without it,
        // every other test here would pass against an embedder returning zeros.
        let related = cosine(result.vectors[0], result.vectors[1])
        let unrelated = cosine(result.vectors[0], result.vectors[2])
        #expect(related > unrelated)
    }

    @Test("no token count is reported, because nothing is billed")
    func metricsOmitTokensOnDevice() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()

        let result = try await embedder.embed(["A short sentence."])

        #expect(result.metrics.inputTokens == nil)
        #expect(result.metrics.vectorCount == 1)
        #expect(result.metrics.dimension == 512)
    }

    // MARK: - Limits

    @Test("input that would be truncated is refused, not silently shortened")
    func overLongInputIsRefused() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()
        // Comfortably past the 256-token window.
        let long = Array(repeating: "The quick brown fox jumped over the lazy dog.", count: 120)
            .joined(separator: " ")

        let outcomes = await embedder.embed([
            RTSRAGChunk(content: long, documentID: RTSRAGDocumentID(UUID()), index: 0)
        ])

        // Truncating would store a vector representing only the beginning of the chunk while
        // retrieval still returned it with a plausible score — worse than a refusal, because
        // nothing downstream could detect it.
        let failure = try #require(outcomes.first?.failure)
        #expect(failure.kind == .invalidInput)
        #expect(failure.kind.isWorthRetrying == false)
        #expect(failure.chunks.count == 1)
    }

    @Test("a chunk under the limit embeds and carries the model identity")
    func chunkPathAttachesIdentity() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()
        let chunk = RTSRAGChunk(
            content: "Refunds are processed within thirty days of receipt.",
            documentID: RTSRAGDocumentID(UUID()),
            index: 3
        )

        let outcomes = await embedder.embed([chunk])

        let embedded = try #require(outcomes.first?.embeddedChunks.first)
        #expect(embedded.chunk.index == 3)
        #expect(embedded.embeddingModel == embedder.modelIdentifier)
        #expect(embedded.embeddingVersion == embedder.embeddingVersion)
        #expect(embedded.vector.count == 512)
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let dot = zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let normLeft = sqrt(lhs.reduce(Float(0)) { $0 + $1 * $1 })
        let normRight = sqrt(rhs.reduce(Float(0)) { $0 + $1 * $1 })
        return dot / (normLeft * normRight)
    }
}
