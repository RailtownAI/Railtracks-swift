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

    @Test("two instances of the same configuration are interchangeable")
    func separateInstancesShareAVectorSpace() async throws {
        let first = try Self.makeEmbedder()
        try await first.prepare()
        let second = try Self.makeEmbedder()
        try await second.prepare()

        let a = try await first.embed(["Refunds are processed within thirty days."])
        let b = try await second.embed(["Refunds are processed within thirty days."])

        // What lets two runtimes write to one store and read each other's chunks. `modelIdentifier`
        // is a pure function of (asset, revision, pooling) — no instance state — so the store's
        // write guard and the runtime's preflight both accept either embedder, and the vectors are
        // identical rather than merely close, so a cross-instance query is not approximating.
        #expect(first.modelIdentifier == second.modelIdentifier)
        #expect(a.vectors == b.vectors)
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

    @Test("dense structured text fits the default budget, where prose-calibrated sizing would not")
    func denseTextFitsTheDefaultBudget() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()
        // Résumé-shaped: bullets, dates, an email, a URL, comma-separated tech. Every one of those
        // fragments into several tokens, so this runs at ~2.06 chars/token against clean prose's
        // 4.13 — a 2× spread, and the reason the default is the floor of that range rather than a
        // midpoint. A prose-calibrated 768 characters rejects this; 512 does not.
        let unit = """
        • Led migration of 12 microservices to Kubernetes (AWS EKS), p99 340ms→85ms
        • Mar 2021 – Aug 2023 | Senior Engineer | mark.su@example.com | github.com/marksu

        """
        var dense = ""
        while dense.count < (embedder.maxInputCharacters ?? 512) {
            dense += unit
        }
        let chunk = RTSRAGChunk(
            content: String(dense.prefix(embedder.maxInputCharacters ?? 512)),
            documentID: RTSRAGDocumentID(UUID()),
            index: 0
        )

        let outcomes = try await embedder.embed([chunk])

        #expect(embedder.maxInputCharacters == 512)
        #expect(outcomes.first?.failure == nil)
        #expect(outcomes.first?.embeddedChunks.first?.vector.count == 512)
    }

    @Test("a prose corpus can opt into double the chunk size")
    func proseCorporaCanWidenTheBudget() throws {
        // Two is the floor of the measured range, not a law: clean prose runs at 4.13 chars/token,
        // so a known-prose corpus doubles its chunk size — and bigger chunks carry more context per
        // hit, which is the whole retrieval-quality argument.
        let prose = try RTSRAGAppleEmbedding(charactersPerToken: 4)

        #expect(prose.maxInputCharacters == 1024)
    }

    @Test("input that would be truncated is refused, not silently shortened")
    func overLongInputIsRefused() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()
        // Comfortably past the 256-token window.
        let long = Array(repeating: "The quick brown fox jumped over the lazy dog.", count: 120)
            .joined(separator: " ")

        let outcomes = try await embedder.embed([
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

    @Test("the refusal suggests a smaller budget, never a larger one")
    func refusalSuggestsASmallerBudget() async throws {
        let embedder = try Self.makeEmbedder()
        try await embedder.prepare()
        // Compact JSON: ~1.2 characters per token, the densest content measured. An earlier version
        // suggested `tokenLimit * 3` = 768 characters here — larger than the 512 that had just
        // failed — because it read a constant instead of the input. Advice that raises the budget
        // you are already over is worse than none.
        let unit = #"{"flow_id":"fd69a02e6fc9b8c052212fc3dccb5706483bab8a2085a0f3cc11f93649ed2c4c","stamp":"2026-09-15T00:10:38.356913+00:00"},"#
        var dense = ""
        while dense.count < 900 {
            dense += unit
        }
        let chunk = RTSRAGChunk(
            content: String(dense.prefix(900)),
            documentID: RTSRAGDocumentID(UUID()),
            index: 0
        )

        let failure = try #require(try await embedder.embed([chunk]).first?.failure)

        let suggested = Self.suggestedCharacters(in: failure.underlying)
        #expect(failure.kind == .invalidInput)
        #expect(suggested != nil)
        #expect((suggested ?? .max) < 900)
    }

    /// Pulls the "chunk to about N characters" figure out of the message.
    private static func suggestedCharacters(in message: String) -> Int? {
        guard let range = message.range(of: "chunk to about ") else {
            return nil
        }
        return Int(message[range.upperBound...].prefix { $0.isNumber })
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

        let outcomes = try await embedder.embed([chunk])

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
