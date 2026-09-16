//
//  RTSRAGEmbeddingResults.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation

// What an embedding call produces, success or failure.
//
// In `Models/` rather than `Embedding/` because these cross the phase boundary: the runtime reads
// metrics to report cost and reads failures to decide whether a document may be committed. The
// line the folders draw is that — types that flow *out* of a stage are models; types internal to a
// stage's mechanics stay with it, which is why `RTSRAGChunkPiece` remains in `Chunkers/`.
//
// `RTSRAGEmbeddedChunk` is the other half of this vocabulary and lives beside `RTSRAGStoreEntry`,
// the type it feeds.

// MARK: - RTSRAGEmbeddingMetrics

/// What the provider reported about one embedding call.
///
/// Every field is optional except the ones measured locally, mirroring Python's
/// `EmbeddingMetrics`, whose docstrings read "if reported by the provider". Shipping `nil` is a
/// degradation rather than a contract break.
///
/// - Note: there is deliberately no `totalCost`. Python does not calculate cost — it reads
///   LiteLLM's `response_cost` from a bundled pricing table, which has no Swift equivalent, and
///   `RTSCostCalculator` sits on the far side of the dependency line this module does not cross.
///   ``inputTokens`` is the provider's own authoritative count; multiplying it by a rate is the
///   caller's business.
public struct RTSRAGEmbeddingMetrics: Sendable, Hashable {
    /// Tokens the provider billed for. `nil` when the provider reports none — always the case for
    /// on-device embedding, which bills nothing.
    public let inputTokens: Int?
    public let latency: TimeInterval
    public let vectorCount: Int
    public let model: String?
    public let dimension: Int?

    public init(
        inputTokens: Int? = nil,
        latency: TimeInterval = 0,
        vectorCount: Int = 0,
        model: String? = nil,
        dimension: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.latency = latency
        self.vectorCount = vectorCount
        self.model = model
        self.dimension = dimension
    }
}

// MARK: - RTSRAGTextEmbeddings

/// Vectors plus what the call reported. The embedder's raw output, before chunks are attached.
public struct RTSRAGTextEmbeddings: Sendable, Hashable {
    public let vectors: [[Float]]
    public let metrics: RTSRAGEmbeddingMetrics

    public init(
        vectors: [[Float]],
        metrics: RTSRAGEmbeddingMetrics = RTSRAGEmbeddingMetrics()
    ) {
        self.vectors = vectors
        self.metrics = metrics
    }
}

// MARK: - RTSRAGEmbeddingFailureKind

/// Why a batch failed, and therefore whether trying again can help.
///
/// Python draws none of these distinctions — `Embedding._embed_one_batch` catches bare `Exception`,
/// so a transient rate limit and an out-of-credit key are handled identically. Without the split, a
/// key with no credit buys a full retry pass on every document in the corpus, silently.
public enum RTSRAGEmbeddingFailureKind: Sendable, Hashable {
    /// 429 with `rate_limit_exceeded`. Clears on backoff — the one kind worth retrying.
    case rateLimited
    /// 429 with `insufficient_quota`. The key is out of credit, so **no amount of retrying or
    /// throttle tuning will help**. Shares a status code with ``rateLimited`` and means the
    /// opposite.
    case quotaExhausted
    /// 4xx — malformed input, or a chunk over the model's input cap. Fails identically forever.
    case invalidInput
    /// 5xx or a network error. Worth one retry.
    case transient
    /// The model itself is unusable: assets missing, revision absent, load failed. Not about this
    /// batch, and retrying the batch cannot fix it.
    case modelUnavailable

    /// Whether a second attempt could plausibly succeed.
    ///
    /// Consulted before retrying, never before *recording* — see ``RTSRAGEmbeddingFailure``.
    public var isWorthRetrying: Bool {
        switch self {
        case .rateLimited, .transient:
            return true
        case .quotaExhausted, .invalidInput, .modelUnavailable:
            return false
        }
    }
}

// MARK: - RTSRAGEmbeddingFailure

/// A batch that could not be embedded, with everything needed to report or re-attempt it.
///
/// **Classification is a label, not a filter.** Failures are recorded whatever their kind, and
/// "is this worth retrying" is asked of the record rather than deciding whether to keep it.
/// Dropping the permanent ones would be cheaper and is wrong three ways: ``quotaExhausted`` is
/// unredeemable this run but redeemable the next after a top-up; the classifier can be wrong,
/// because provider error bodies vary by tier and change over time, and a misread
/// ``invalidInput`` is unrecoverable once its chunks are gone; and the permanent failures are
/// exactly the ones a human has to act on.
///
/// The same call was made for the loader stream's `.failure` elements and for preserving blank CSV
/// rows — do not discard data at a layer that cannot reconstruct it.
public struct RTSRAGEmbeddingFailure: Sendable {
    /// The work itself. Carried whole rather than by id, because nothing has stored these yet.
    public let chunks: [RTSRAGChunk]
    public let kind: RTSRAGEmbeddingFailureKind
    /// The provider's raw message. What a human debugs with, and what allows a wrong verdict to be
    /// re-read later.
    public let underlying: String
    /// Which embedder produced this. A retry under a different model would write vectors into a
    /// space the rest of the document is not in.
    public let modelIdentifier: String
    public let occurredAt: Date
    /// `1` when the batch failed outright, `2` when it also failed its retry. Lets a report tell
    /// "the provider is down" from "this input is bad".
    public let attempts: Int

    public init(
        chunks: [RTSRAGChunk],
        kind: RTSRAGEmbeddingFailureKind,
        underlying: String,
        modelIdentifier: String,
        occurredAt: Date = Date(),
        attempts: Int = 1
    ) {
        self.chunks = chunks
        self.kind = kind
        self.underlying = underlying
        self.modelIdentifier = modelIdentifier
        self.occurredAt = occurredAt
        self.attempts = attempts
    }

    /// The same failure, recorded as having taken one more attempt.
    func afterAnotherAttempt(kind: RTSRAGEmbeddingFailureKind, underlying: String) -> Self {
        RTSRAGEmbeddingFailure(
            chunks: chunks,
            kind: kind,
            underlying: underlying,
            modelIdentifier: modelIdentifier,
            occurredAt: Date(),
            attempts: attempts + 1
        )
    }
}

// MARK: - RTSRAGEmbeddingBatchOutcome

/// One batch's result: vectors, or a recorded failure.
///
/// A failed batch does not end the run, matching how one unreadable file does not abandon a
/// directory. The caller decides what a partial document means — in the pipeline that decision is
/// the store commit, which only happens when every batch succeeded.
public enum RTSRAGEmbeddingBatchOutcome: Sendable {
    case embedded([RTSRAGEmbeddedChunk], RTSRAGEmbeddingMetrics)
    case failed(RTSRAGEmbeddingFailure)

    public var embeddedChunks: [RTSRAGEmbeddedChunk] {
        switch self {
        case .embedded(let chunks, _):
            return chunks
        case .failed:
            return []
        }
    }

    public var failure: RTSRAGEmbeddingFailure? {
        switch self {
        case .embedded:
            return nil
        case .failed(let failure):
            return failure
        }
    }
}
