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

    /// The store could not complete an operation.
    case storeFailed(reason: String)
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
        case .storeFailed(let reason):
            return "store operation failed: \(reason)"
        }
    }
}
