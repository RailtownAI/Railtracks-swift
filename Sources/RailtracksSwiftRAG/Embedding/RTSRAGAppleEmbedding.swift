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
    ///   - charactersPerToken: how densely the corpus tokenizes, used only to size
    ///     ``maxInputCharacters``. Defaults to a pessimistic 2; pass 4 for known-prose corpora and
    ///     get roughly double the chunk size. See ``defaultCharactersPerToken`` for the
    ///     measurements behind both figures.
    public init(
        revision: Int = 1,
        language: NLLanguage = .english,
        pooling: Pooling = .mean,
        charactersPerToken: Int = RTSRAGAppleEmbedding.defaultCharactersPerToken
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
        self.maxInputCharacters = model.maximumSequenceLength * max(1, charactersPerToken)
    }

    /// How many characters fit in one token, for sizing ``maxInputCharacters``.
    ///
    /// **Two is deliberately pessimistic, and the spread is why.** Measured against this model:
    ///
    /// | Text | chars/token | 255-token ceiling |
    /// |---|---|---|
    /// | clean English prose | 4.13 | ~1,050 characters |
    /// | résumé / structured | 2.06 | ~525 characters |
    ///
    /// A 2× spread, so **no single constant serves both** — and it is content shape, not language,
    /// that moves it. Emails, URLs, date ranges, bullet glyphs, code identifiers and acronyms all
    /// fragment into many tokens each, so a page of CV bullets is twice as dense as a page of
    /// narrative. An earlier default of three sat between the two and was wrong for both: it wasted
    /// half the window on prose and still rejected résumé text.
    ///
    /// Two is therefore the floor of the measured range, chosen because the asymmetry favours it —
    /// under-estimating costs chunk size, which degrades retrieval a little; over-estimating costs
    /// whole chunks, which lose content entirely. Callers whose corpus is known-prose should pass
    /// `charactersPerToken: 4` and get roughly double the chunk size.
    ///
    /// Non-English is unmeasured and takes the same figure. Space-less scripts — Chinese,
    /// Japanese, Korean, Thai — plausibly run denser still; measuring is a few lines, embedding a
    /// representative string and counting what `enumerateTokenVectors` yields.
    ///
    /// Whatever value is used, this is only a pre-filter. The real guard is the post-tokenization
    /// check in ``embed(_:)``, which counts actual tokens and cannot be fooled by content shape —
    /// so a bad figure costs refusals, never a silently truncated vector.
    public static let defaultCharactersPerToken = 2

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
            // Measured from *this* input rather than a constant. An earlier version suggested
            // `tokenLimit * 3` characters, which on dense content advised a budget **larger** than
            // the one already failing — a 512-character chunk was told to try 768. No fixed number
            // can be right across the measured range: clean prose runs at 4.1 characters per
            // token, résumé text at 2.1, compact JSON at 1.2. Only the offending text knows.
            let density = Double(text.count) / Double(tokenCount)
            // A margin below the ceiling, since the next chunk of the same source will not have
            // exactly this density.
            let suggested = Int(Double(tokenLimit - 32) * density)
            throw RTSRAGEmbeddingError(
                kind: .invalidInput,
                message: """
                \(text.count) characters produced \(tokenCount) tokens, reaching the \
                \(tokenLimit)-token limit, so the tail would be dropped; this content runs at \
                \(String(format: "%.1f", density)) characters per token, so chunk to about \
                \(suggested) characters
                """
            )
        }
        return sum.map { Float($0 / Double(tokenCount)) }
    }
}
