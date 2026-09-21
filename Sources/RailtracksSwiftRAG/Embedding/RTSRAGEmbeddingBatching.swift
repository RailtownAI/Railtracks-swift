//
//  RTSRAGEmbeddingBatching.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-16.
//

import Foundation

public extension RTSRAGEmbedding {

    /// Embeds chunks in batches, isolating failures and retrying the ones worth retrying.
    ///
    /// The equivalent of Python's `Chunker.astream_batches`, with the two things it lacks: failures
    /// are **classified**, and transient ones get one bounded retry.
    ///
    /// **The retry happens here, before anything is stored, and that ordering is the design.**
    /// Because a document is embedded whole before it is committed, a batch that never succeeds
    /// simply means *not committing* — the previous version stays intact and no partial document
    /// is ever written. Python writes the batches that succeeded and leaves the document knowingly
    /// partial; this avoids that state rather than recovering from it.
    ///
    /// Scope is one call, which in the pipeline is one document. Per-document rather than a
    /// global end-of-run sweep because a global one would hold every embedded vector for the whole
    /// corpus in memory until the run ended, and would make each document wait on the slowest.
    ///
    /// - Parameters:
    ///   - chunks: The chunks to embed, in order.
    ///   - batchSize: Texts per request. Defaults to ``RTSRAGEmbedding/defaultBatchSize``.
    ///   - maxAttempts: Attempts per batch, including the first. `1` disables retrying.
    /// - Returns: One outcome per batch, in batch order. A batch that cannot be embedded comes back
    ///   as ``RTSRAGEmbeddingBatchOutcome/failed(_:)`` carrying its chunks.
    /// - Throws: ``RTSRAGEmbeddingError`` when the **embedder** is unusable rather than the batch —
    ///   an exhausted account or an unavailable model. That is the same line the loaders draw
    ///   between a precondition and a per-item failure, and it is what stops a dead API key
    ///   spending one doomed request per remaining batch, for every document in the corpus.
    ///
    ///   Nothing useful is lost by abandoning the outcomes already collected: a document holding
    ///   any failure of this class is not committed anyway, so those embeddings were never going to
    ///   be stored.
    func embed(
        _ chunks: [RTSRAGChunk],
        batchSize: Int? = nil,
        maxAttempts: Int = 2
    ) async throws -> [RTSRAGEmbeddingBatchOutcome] {
        guard !chunks.isEmpty else {
            return []
        }
        let size = max(1, batchSize ?? defaultBatchSize)
        var outcomes: [RTSRAGEmbeddingBatchOutcome] = []
        var index = 0
        while index < chunks.count {
            let batch = Array(chunks[index..<min(index + size, chunks.count)])
            // `contentsOf`, because a batch rejected for its *content* is split to isolate the
            // offender and therefore yields several outcomes rather than one.
            let batchOutcomes = await embedOneBatch(batch, maxAttempts: maxAttempts)
            if let fatal = batchOutcomes.compactMap({ $0.failure }).first(where: { $0.kind.endsTheRun }) {
                throw RTSRAGEmbeddingError(
                    kind: fatal.kind,
                    message: "embedding stopped after \(outcomes.count) batch(es): \(fatal.underlying)"
                )
            }
            outcomes.append(contentsOf: batchOutcomes)
            index += size
        }
        return outcomes
    }

    /// Embeds one batch, retrying while the failure kind says a retry could help and splitting it
    /// when the provider rejects its *content*.
    ///
    /// Returns several outcomes when it splits, which is why the caller appends `contentsOf`.
    private func embedOneBatch(
        _ batch: [RTSRAGChunk],
        maxAttempts: Int
    ) async -> [RTSRAGEmbeddingBatchOutcome] {
        var lastFailure: RTSRAGEmbeddingFailure?
        for attempt in 1...max(1, maxAttempts) {
            do {
                let embedded = try await embedExactly(batch)
                return [.embedded(embedded.chunks, embedded.metrics)]
            } catch {
                let kind = RTSRAGEmbeddingFailureKind(from: error)
                let reason = "\(error)"
                if let previous = lastFailure {
                    lastFailure = previous.afterAnotherAttempt(kind: kind, underlying: reason)
                } else {
                    lastFailure = RTSRAGEmbeddingFailure(
                        chunks: batch,
                        kind: kind,
                        underlying: reason,
                        modelIdentifier: modelIdentifier,
                        attempts: attempt
                    )
                }
                // Rejected for its content, so split and find out which chunk. One over-long or
                // malformed chunk would otherwise deny every other chunk in the batch — up to 512
                // against OpenAI, whose array request the provider refuses as a unit — and,
                // through the phase 6 commit rule, the whole document with them.
                //
                // Only for `.invalidInput`: a rate limit or an exhausted quota is a condition of
                // the *account*, not of the content, so halving there would double the requests
                // while already being refused.
                //
                // Python avoids this case up front instead, measuring each chunk in
                // `_split_oversized` and failing it alone. That needs a tokenizer, which is the
                // one thing this module cannot have — so the same protection has to be discovered
                // rather than predicted. Isolating one bad chunk costs ~log2(batch) extra
                // requests, and nothing at all when batches succeed.
                if kind == .invalidInput, batch.count > 1 {
                    let middle = batch.count / 2
                    let first = await embedOneBatch(Array(batch[..<middle]), maxAttempts: maxAttempts)
                    let second = await embedOneBatch(Array(batch[middle...]), maxAttempts: maxAttempts)
                    return first + second
                }
                // A permanent failure is returned immediately rather than after burning the
                // attempt budget: an out-of-credit key would otherwise buy a second full pass over
                // every document in the corpus, and a malformed input fails identically forever.
                guard kind.isWorthRetrying else {
                    break
                }
            }
        }
        // Unreachable with a sane `maxAttempts`, but the type has to be total.
        return [
            .failed(
                lastFailure
                    ?? RTSRAGEmbeddingFailure(
                        chunks: batch,
                        kind: .transient,
                        underlying: "embedding produced no result",
                        modelIdentifier: modelIdentifier
                    )
            )
        ]
    }

    /// One call, with the vector count verified against the input count.
    ///
    /// Ported from Python's `_embed_one_batch`, which raises when the provider returns a different
    /// number of vectors than inputs. Without the guard, a short response mis-pairs every vector
    /// after the gap — chunk *n* silently gets chunk *n+1*'s embedding, which no downstream check
    /// could catch because both values are well-formed.
    private func embedExactly(
        _ batch: [RTSRAGChunk]
    ) async throws -> (chunks: [RTSRAGEmbeddedChunk], metrics: RTSRAGEmbeddingMetrics) {
        let result = try await embed(batch.map { $0.content })
        guard result.vectors.count == batch.count else {
            throw RTSRAGError.embeddingFailed(
                reason: "provider returned \(result.vectors.count) vectors for \(batch.count) inputs"
            )
        }
        let embedded = zip(batch, result.vectors).map { chunk, vector in
            RTSRAGEmbeddedChunk(
                chunk: chunk,
                vector: vector,
                embeddingModel: modelIdentifier,
                embeddingVersion: embeddingVersion
            )
        }
        return (embedded, result.metrics)
    }
}

// MARK: - Classification

extension RTSRAGEmbeddingFailureKind {
    /// The kind an arbitrary error represents.
    ///
    /// Provider-specific errors classify themselves by conforming to
    /// ``RTSRAGClassifiedEmbeddingError`` — the body shape varies by provider and account tier, so
    /// the parsing belongs with the embedder that knows it, not in a shared table here.
    init(from error: Error) {
        if let classified = error as? any RTSRAGClassifiedEmbeddingError {
            self = classified.embeddingFailureKind
            return
        }
        if error is CancellationError {
            self = .transient
            return
        }
        if let urlError = error as? URLError {
            self = urlError.code == .badURL ? .invalidInput : .transient
            return
        }
        self = .transient
    }
}

/// An error that knows which failure kind it represents.
///
/// Implemented by each embedder for its own provider, so a custom Cohere or Voyage embedder gets
/// the batching, retry and reporting above by writing only its classifier.
public protocol RTSRAGClassifiedEmbeddingError: Error {
    var embeddingFailureKind: RTSRAGEmbeddingFailureKind { get }
}

/// A ready-made classified error, so an embedder needs no error type of its own.
public struct RTSRAGEmbeddingError: RTSRAGClassifiedEmbeddingError, Sendable, CustomStringConvertible {
    public let kind: RTSRAGEmbeddingFailureKind
    public let message: String

    public init(
        kind: RTSRAGEmbeddingFailureKind,
        message: String
    ) {
        self.kind = kind
        self.message = message
    }

    public var embeddingFailureKind: RTSRAGEmbeddingFailureKind {
        kind
    }

    public var description: String {
        message
    }
}
