//
//  RTSRAGError.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

/// Errors raised by the retrieval pipeline.
///
/// Local to this module rather than a case on `RTSError`, so the model and pipeline layers carry
/// no RailtracksSwift import and the module stays cheap to lift out.
public enum RTSRAGError: Error, Sendable, Equatable {
    /// The embedder reported a model different from the one the store was built with.
    ///
    /// Fatal rather than a warning: similarity scores across models are not comparable, so a
    /// mixed index returns confidently wrong rankings. Conduit compounds this by returning `0`
    /// from `cosineSimilarity` on a dimension mismatch instead of throwing, which would otherwise
    /// present as "nothing matches anything" with no indication why.
    case embeddingModelMismatch(expected: String, found: String)

    /// A chunk exceeded the provider's input limit.
    ///
    /// Should be unreachable while chunk size is enforced in characters, which caps token count
    /// by construction. Reachable if a loader ever emits pre-chunked content that bypasses a
    /// chunker.
    case chunkTooLarge(chunkID: RTSRAGChunkID, characters: Int, limit: Int)

    /// A loader could not read its source.
    case loadFailed(source: String, reason: String)

    /// The embedding provider failed for a batch.
    case embeddingFailed(reason: String)

    /// The embedding model itself cannot be used: assets missing, revision absent, load failed.
    ///
    /// Distinct from ``embeddingFailed(reason:)``, which is about one batch. This is about the
    /// embedder, so no batch can succeed until it is resolved — and on-device embedding is the
    /// only path that has it, since a hosted model is either reachable or a network failure.
    case embeddingModelUnavailable(reason: String)

    /// The on-device model is not on the device yet, and the caller stopped waiting for it.
    ///
    /// Not a failure, unlike ``embeddingModelUnavailable(reason:)``: the download keeps running,
    /// and a later `prepare` waits on it. Apple reports no progress and no size, so a timeout can
    /// only mean "not within the time this caller was willing to wait", never "will not arrive".
    /// An app offers to wait longer, or switches to another embedder.
    case embeddingModelNotReady(reason: String)

    /// The store could not complete an operation.
    case storeFailed(reason: String)

    /// A second ingest was started on a runtime already running one.
    ///
    /// A programming error, not a runtime condition, so it fails fast rather than queueing. One
    /// runtime is one ingest at a time, which is what makes its event stream unambiguous — the
    /// events carry a document id but no run id, and they do not need one while this holds.
    ///
    /// Concurrency comes from a **second runtime**, which is a plain object over the same embedder
    /// and store, so it costs nothing to make. Throwing rather than waiting is deliberate: a caller
    /// who wrapped two ingests in a task group expecting parallelism would otherwise get silent
    /// serialisation, a run that takes twice as long and looks correct.
    case ingestAlreadyRunning
}

// MARK: - CustomStringConvertible

extension RTSRAGError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .embeddingModelMismatch(let expected, let found):
            return """
            embedding model mismatch: store was built with \(expected) but the embedder produced \
            \(found). Similarity scores across models are meaningless — rebuild the store or \
            switch back to the original embedder.
            """
        case .chunkTooLarge(let chunkID, let characters, let limit):
            return "chunk \(chunkID) is \(characters) characters, over the \(limit) limit"
        case .loadFailed(let source, let reason):
            return "could not load \(source): \(reason)"
        case .embeddingFailed(let reason):
            return "embedding failed: \(reason)"
        case .embeddingModelUnavailable(let reason):
            return "embedding model unavailable: \(reason)"
        case .embeddingModelNotReady(let reason):
            return "embedding model not ready: \(reason)"
        case .storeFailed(let reason):
            return "store operation failed: \(reason)"
        case .ingestAlreadyRunning:
            return """
            this runtime is already ingesting. One runtime runs one ingest at a time; build a \
            second runtime over the same embedder and store to ingest concurrently.
            """
        }
    }
}
