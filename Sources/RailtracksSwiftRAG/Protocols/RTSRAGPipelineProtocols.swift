//
//  RTSRAGPipelineProtocols.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

// MARK: - RTSRAGDocumentLoader

/// Produces documents to ingest.
///
/// The loader decides *what* is processed; the chunker, embedder and store decide *how*. A
/// loader is free to emit one document per file, per section, or per database row — and that
/// choice is the main lever over update cost, because a document is the unit that gets replaced.
///
/// A loader also assigns ``RTSRAGDocument/source``, which derives the document id and is therefore
/// the key an update replaces on. Getting it wrong turns an update into a silent duplicate.
public protocol RTSRAGDocumentLoader: Sendable {
    /// Streams documents lazily, so a large corpus is never fully resident.
    ///
    /// Per-item failures arrive as `.failure` elements rather than ending the stream, so one
    /// unreadable file in a directory does not abandon the rest.
    ///
    /// Throwing is reserved for failures that make the *whole* stream meaningless and can be
    /// detected before reading anything — a root path that does not exist, or one that is not a
    /// supported type. Those surface here, at the call site, rather than as the first element.
    /// A per-file problem discovered while reading, including a CSV whose header lacks a
    /// configured column, stays a `.failure`: in a directory each file has its own header, and one
    /// mismatched schema should not abandon the rest.
    func stream() throws -> RTSRAGDocumentStream
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
///
/// Conformers implement only ``embed(_:)-(\[String\])`` — the single-call primitive. Batching,
/// per-batch failure isolation and the bounded retry come from a protocol extension, so a custom
/// embedder inherits them rather than re-deriving them. See ``embed(_:batchSize:)``.
///
/// - Note: nothing throttle-shaped appears here, deliberately. Rate limiting is a property of some
///   implementations and not others: an HTTP embedder composes an ``RTSRAGRateGovernor``, while
///   ``RTSRAGAppleEmbedding`` runs on-device with no quota and needs actor isolation instead. They
///   are two different problems, not one policy configured differently.
public protocol RTSRAGEmbedding: Sendable {
    /// The full identity of the model, recorded on every entry so a later query can refuse an
    /// index built by a different one.
    ///
    /// **Not a friendly name.** Anything that changes the vector space belongs in it — the model,
    /// its revision, and for models returning per-token vectors, the pooling strategy. Two
    /// embedders differing only in pooling produce incomparable vectors from identical weights, so
    /// a name that omitted it would let ``RTSRAGError/embeddingModelMismatch`` pass a store it
    /// should have refused.
    var modelIdentifier: String { get }
    /// The model's own version, when it has one distinct from the identifier.
    var embeddingVersion: String? { get }
    /// How many texts to send per request, when the provider supports batching.
    var defaultBatchSize: Int { get }
    /// The longest single input this model accepts, or `nil` when effectively unbounded.
    ///
    /// Declared so a mismatch with the chunker's budget is *detectable* rather than silently
    /// truncated — on-device embedding caps at 256 tokens, which is roughly the same 1,024
    /// characters the sentence chunker defaults to.
    var maxInputCharacters: Int? { get }

    func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings
}

public extension RTSRAGEmbedding {
    var embeddingVersion: String? {
        nil
    }

    var maxInputCharacters: Int? {
        nil
    }
}

// MARK: - RTSRAGVectorStore

/// Persists entries and serves similarity search. Phase 5.
///
/// ## One embedding model per instance
///
/// Every entry one conformer instance exposes must share one embedding model and one vector
/// width. An empty instance has neither, so whichever model writes next establishes them. A write
/// from a different model should throw ``RTSRAGError/embeddingModelMismatch(expected:found:)``.
///
/// The rest of the API depends on it: scores across two models are meaningless while remaining
/// well-formed, ``replaceDocument(id:with:)`` and ``deleteDocument(id:)`` are keyed by document
/// alone, ``RTSRAGStoreQuery`` carries no model, and ``RTSRAGRetrievalRuntime`` checks the
/// embedder against a single sampled entry.
///
/// The rule is about what an **instance** exposes, not how storage is laid out. Several models may
/// share one physical backend, provided each is exposed through its own conformer — a per-model
/// view that keys entries by document *and* model and sees only its own:
///
/// ```swift
/// let backend = SharedVectorBackend(...)
/// let small = RTSRAGRetrievalRuntime(embedder: e1, store: backend.view(for: e1.modelIdentifier))
/// let large = RTSRAGRetrievalRuntime(embedder: e2, store: backend.view(for: e2.modelIdentifier))
/// ```
///
/// What no conformer may do is mix models behind one instance.
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
