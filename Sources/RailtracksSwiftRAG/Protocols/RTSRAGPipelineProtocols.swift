//
//  RTSRAGPipelineProtocols.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

// MARK: - RTSRAGDocumentLoader

/// Produces documents to ingest. Phase 2.
///
/// The loader decides *what* is processed; the chunker, embedder and store decide *how*. A
/// loader is free to emit one document per file, per section, or per database row — and that
/// choice is the main lever over update cost, because a document is the unit that gets replaced.
public protocol RTSRAGDocumentLoader: Sendable {
    /// Streams documents lazily, so a large source is never fully resident.
    func stream() -> AsyncThrowingStream<RTSRAGDocument, Error>
}

// MARK: - RTSRAGChunker

/// Splits a document into embeddable pieces. Phase 3.
///
/// Takes the whole document rather than its text, because chunks have to carry the document's id
/// and inherit its metadata.
///
/// - Important: a conformer must not exceed ``RTSRAGLimits/defaultMaxChunkCharacters``. Enforcing
///   the size here, in characters, is what makes a token counter unnecessary — see
///   ``RTSRAGLimits``.
public protocol RTSRAGChunker: Sendable {
    func chunk(_ document: RTSRAGDocument) async throws -> [RTSRAGChunk]
}

// MARK: - RTSRAGEmbedding

/// Turns text into vectors. Phase 4.
public protocol RTSRAGEmbedding: Sendable {
    /// The model these vectors come from, recorded on every entry so a later query can verify it
    /// is searching an index built by the same embedder.
    var modelIdentifier: String { get }
    /// How many texts to send per request, when the provider supports batching.
    var defaultBatchSize: Int { get }

    func embed(_ texts: [String]) async throws -> [RTSRAGEmbeddingVector]
}

/// One embedding result: the vector and the model that produced it.
public struct RTSRAGEmbeddingVector: Sendable, Hashable {
    public let vector: [Float]
    public let model: String

    public init(
        vector: [Float],
        model: String
    ) {
        self.vector = vector
        self.model = model
    }
}

// MARK: - RTSRAGVectorStore

/// Persists entries and serves similarity search. Phase 5.
public protocol RTSRAGVectorStore: Sendable {
    /// Replaces every entry for `id` with `entries`, as **one operation**.
    ///
    /// A single operation rather than a delete followed by writes, which is where the Python
    /// design leaves a gap: there, updating a document deletes its rows and then streams writes
    /// with embedding round trips in between, so a second ingest of the same document can
    /// interleave and leave it half-deleted. No store-side locking closes that, because the
    /// delete and the writes are separate awaits.
    ///
    /// Making replacement the unit lets a transactional backend be genuinely atomic, and a
    /// non-transactional one serialise per document — instead of leaving correctness to a
    /// convention nobody wrote down.
    func replaceDocument(
        id: RTSRAGDocumentID,
        with entries: [RTSRAGStoreEntry]
    ) async throws

    /// Ranked nearest neighbours.
    ///
    /// - Important: a conformer must reject a query whose vector dimension disagrees with the
    ///   stored entries rather than scoring it. Conduit's `cosineSimilarity` returns `0` on a
    ///   mismatch, which would otherwise present as "nothing matches" with no indication why.
    func search(_ query: RTSRAGStoreQuery) async throws -> [RTSRAGRetrievedEntry]

    func deleteDocument(id: RTSRAGDocumentID) async throws

    /// Entries matching flat equality filters, without a vector search. Used by the staleness
    /// check to decide whether a document is already stored and complete.
    func find(
        matching filters: RTSRAGMetadata,
        limit: Int
    ) async throws -> [RTSRAGStoreEntry]

    /// How many entries match `filters`. Separate from ``find(matching:limit:)`` so a
    /// completeness check never transfers payloads it does not need.
    func count(matching filters: RTSRAGMetadata) async throws -> Int
}

// MARK: - RTSRAGTokenCounting

/// Counts tokens for a model. **No implementation ships yet** — see ``RTSRAGLimits``.
///
/// Declared as a seam because two things will eventually want it, neither of which blocks the
/// pipeline: budgeting how many retrieved chunks fit in a prompt, and tuning chunk size against a
/// corpus, where tokens are the natural unit rather than characters.
///
/// Nothing available can count OpenAI tokens accurately today: Conduit's `countTokens` is
/// `text.count / 4` and admits to "±50% or more", and swift-transformers carries no tiktoken
/// vocabulary.
public protocol RTSRAGTokenCounting: Sendable {
    func count(_ text: String) -> Int
}
