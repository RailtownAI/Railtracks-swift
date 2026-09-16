//
//  RTSRAGAppleEmbedding.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation
import NaturalLanguage

/// On-device embedding through Apple's `NLContextualEmbedding`.
///
/// Free, offline, deterministic, and subject to no quota — so none of the throttle, retry or cost
/// machinery the cloud path needs applies here. What it needs instead is isolation: the underlying
/// model is a non-`Sendable` reference type whose `load()` the header warns is expensive, so this
/// is an `actor` that loads once and serialises use.
///
/// - Important: **not Apple Intelligence.** `FoundationModels` exposes no embedding API — Conduit's
///   own protocol documentation says so outright. This is the `NaturalLanguage` framework, which
///   predates it, needs no entitlement, no key and no user opt-in, and runs on every supported OS.
///
/// Two limits shape where it fits:
///
/// - **256 tokens**, against the sentence chunker's 1,024-character default. Chunks sit right at
///   the ceiling, so pair it with `RTSRAGSentenceChunker(maxCharacters: 768)`. Truncation is
///   detected rather than assumed — see ``embed(_:)``.
/// - **Apple platforms only.** A store built with it can be *read* anywhere, since similarity is
///   arithmetic over floats, but only an Apple device can turn text into a vector — which means
///   both ingest and query need one.
public actor RTSRAGAppleEmbedding: RTSRAGEmbedding {

    /// How per-token vectors become one vector.
    ///
    /// The model returns a vector *per token*, unlike a hosted embedder which returns one per
    /// input, so combining them is our decision — and it is part of the vector space. Two
    /// embedders differing only here produce incomparable vectors from identical weights, which is
    /// why the choice is named in ``modelIdentifier``.
    public enum Pooling: String, Sendable {
        /// Mean of the token vectors. The usual choice, and what sentence-level similarity assumes.
        case mean
    }

    public nonisolated let modelIdentifier: String
    public nonisolated let embeddingVersion: String?
    public nonisolated let maxInputCharacters: Int?
    /// One at a time: the model is serial and there is no request to batch into.
    public nonisolated let defaultBatchSize = 1

    private let model: NLContextualEmbedding
    private let language: NLLanguage
    private let tokenLimit: Int
    private var isLoaded = false

    /// - Parameters:
    ///   - revision: The model revision to pin. **Pinned rather than defaulted to "latest"
    ///     deliberately**: `NLContextualEmbedding(language:)` resolves the most recent revision, so
    ///     two devices on different OS versions would silently embed into different vector spaces
    ///     and compare them against each other. A pinned revision that is absent fails here, at
    ///     construction, instead of returning confidently wrong rankings at query time.
    ///   - language: Which model to resolve. One multilingual model covers 20 languages.
    ///   - pooling: How per-token vectors are combined. Part of the recorded identity.
    /// - Throws: ``RTSRAGError/embeddingModelUnavailable(reason:)`` when no model matches, which on
    ///   a device missing that revision is the correct, loud outcome.
    public init(
        revision: Int = 1,
        language: NLLanguage = .english,
        pooling: Pooling = .mean
    ) throws {
        let candidates = NLContextualEmbedding.contextualEmbeddings(
            forValues: [
                .languages: [language.rawValue],
                .revision: revision,
            ]
        )
        guard let model = candidates.first else {
            throw RTSRAGError.embeddingModelUnavailable(
                reason: "no contextual embedding for \(language.rawValue) at revision \(revision)"
            )
        }
        self.model = model
        self.language = language
        self.tokenLimit = model.maximumSequenceLength
        self.embeddingVersion = "rev\(model.revision)"
        // Everything that changes the vector space, in one string: the asset, its revision, and
        // the pooling. A friendly name would let a store built under different pooling pass the
        // mismatch guard.
        self.modelIdentifier = "nl-contextual/\(model.modelIdentifier)/rev\(model.revision)/\(pooling.rawValue)"
        self.maxInputCharacters = model.maximumSequenceLength
            * RTSRAGAppleEmbedding.charactersPerToken(for: language)
    }

    /// How many characters of `language` fit in one token, for sizing ``maxInputCharacters``.
    ///
    /// **Only English is measured.** 460 characters of English prose produced 141 token vectors
    /// (~3.26 per token), with saturation arriving around 830 characters — so three is the safe
    /// rounding. An earlier draft used four and sat *past* the real ceiling, which is the wrong
    /// direction for a guard.
    ///
    /// Every other language is a placeholder returning the same figure, and **each one should be
    /// measured before it is trusted**. The ratio varies enormously: languages written without
    /// spaces — Chinese, Japanese, Korean, Thai — run far denser, plausibly near one character per
    /// token, so three would over-permit by roughly 3×. Measuring is a few lines: embed a
    /// representative string and count the vectors `enumerateTokenVectors` yields.
    ///
    /// Getting this wrong is **not dangerous, only wasteful**, which is why a placeholder is
    /// acceptable in the meantime. The real guard is the post-tokenization check in
    /// ``embed(_:)``, which counts actual tokens and is language-independent — so an
    /// under-estimated ratio produces refusals (`.invalidInput`), never silent truncation. The
    /// cost of a bad figure is a high rejection rate and a lot of pointless bisecting, not a
    /// corrupt store.
    ///
    /// Whatever value lands here, the chunker has to be paired to match:
    /// `RTSRAGSentenceChunker(maxCharacters:)` at or below this number.
    private static func charactersPerToken(for language: NLLanguage) -> Int {
        switch language {
        case .english:
            return 3
        default:
            // Unmeasured. Kept at the English figure so behaviour is unchanged until someone
            // measures the language they actually need, rather than guessing lower and silently
            // rejecting text that would have fitted.
            return 3
        }
    }

    /// Downloads the model assets if the device does not already have them.
    ///
    /// A state the cloud path has no equivalent of: `hasAvailableAssets` can be false on a fresh
    /// device. Call this before a first ingest, or let ``embed(_:)`` fail with
    /// ``RTSRAGEmbeddingFailureKind/modelUnavailable`` and surface that to the user.
    public func prepare() async throws {
        guard !model.hasAvailableAssets else {
            try loadIfNeeded()
            return
        }
        let result = try await model.requestAssets()
        guard result == .available else {
            throw RTSRAGError.embeddingModelUnavailable(
                reason: "assets unavailable for \(modelIdentifier) (\(result))"
            )
        }
        try loadIfNeeded()
    }

    public func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        guard !texts.isEmpty else {
            return RTSRAGTextEmbeddings(vectors: [])
        }
        try loadIfNeeded()
        let started = Date()
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(try vector(for: text))
        }
        return RTSRAGTextEmbeddings(
            vectors: vectors,
            metrics: RTSRAGEmbeddingMetrics(
                // No token count and no cost: nothing is billed, so there is nothing to report.
                inputTokens: nil,
                latency: Date().timeIntervalSince(started),
                vectorCount: vectors.count,
                model: modelIdentifier,
                dimension: vectors.first?.count
            )
        )
    }

    // MARK: - Internals

    private func loadIfNeeded() throws {
        guard !isLoaded else {
            return
        }
        guard model.hasAvailableAssets else {
            throw RTSRAGEmbeddingError(
                kind: .modelUnavailable,
                message: "assets not downloaded for \(modelIdentifier); call prepare() first"
            )
        }
        do {
            // Loaded once and kept: the header warns the first load is expensive.
            try model.load()
        } catch {
            throw RTSRAGEmbeddingError(
                kind: .modelUnavailable,
                message: "could not load \(modelIdentifier): \(error)"
            )
        }
        isLoaded = true
    }

    private func vector(for text: String) throws -> [Float] {
        guard !text.isEmpty else {
            throw RTSRAGEmbeddingError(kind: .invalidInput, message: "cannot embed empty text")
        }
        let result: NLContextualEmbeddingResult
        do {
            result = try model.embeddingResult(for: text, language: language)
        } catch {
            throw RTSRAGEmbeddingError(
                kind: .invalidInput,
                message: "embedding failed for a \(text.count)-character input: \(error)"
            )
        }

        var sum: [Double] = []
        var tokenCount = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            if sum.isEmpty {
                sum = vector
            } else if sum.count == vector.count {
                for index in vector.indices {
                    sum[index] += vector[index]
                }
            }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0, !sum.isEmpty else {
            throw RTSRAGEmbeddingError(
                kind: .invalidInput,
                message: "no tokens produced for a \(text.count)-character input"
            )
        }
        // Truncation is *measured*, not guessed from a character estimate. Reaching the sequence
        // limit means the tail of the chunk contributed nothing to the vector, so the stored
        // embedding would silently represent only its beginning — worse than a refusal, because
        // retrieval would still return it with a plausible score.
        //
        // The saturation point is `maximumSequenceLength - 1`, not the limit itself: one slot goes
        // to a model-internal token, so enumeration tops out at 255 of a declared 256. Measured —
        // 2,300 characters and 18,400 characters both yield exactly 255. A genuine 255-token input
        // is refused too, which is the safe direction: the caller is told to chunk smaller rather
        // than handed a vector representing only part of the text.
        guard tokenCount < tokenLimit - 1 else {
            throw RTSRAGEmbeddingError(
                kind: .invalidInput,
                message: """
                input reached the \(tokenLimit)-token limit and would be truncated; \
                chunk to about \(tokenLimit * 3) characters for this model
                """
            )
        }
        return sum.map { Float($0 / Double(tokenCount)) }
    }
}
