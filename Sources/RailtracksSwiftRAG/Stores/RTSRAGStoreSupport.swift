//
//  RTSRAGStoreSupport.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-18.
//

import Foundation

// MARK: - RTSRAGStoreIndex

/// The state both shipped stores keep, and the rules they both enforce.
///
/// Factored out rather than given a second public protocol: Python separates `VectorStore` from
/// `VectorBackend` so its entry mapping is written once, but that split is internal reuse and not
/// something the pipeline sees. ``RTSRAGVectorStore`` stays a single seam and each conformer owns
/// its own storage; this is just the part they happen to share.
struct RTSRAGStoreIndex {

    /// Keyed by document, not a flat list of entries.
    ///
    /// That is what makes `replaceDocument` and `deleteDocument` a dictionary write rather than a
    /// scan, and it matches the unit the file format persists — a document's chunks land together
    /// or not at all.
    private(set) var documents: [RTSRAGDocumentID: [RTSRAGStoreEntry]] = [:]
    /// The identity every entry must share, taken from the first one written.
    private(set) var embeddingModel: String?
    private(set) var dimension: Int?

    var entries: [RTSRAGStoreEntry] {
        documents.values.flatMap { $0 }
    }

    var isEmpty: Bool {
        documents.isEmpty
    }

    // MARK: Mutation

    /// Validates `entries` against the store's established vector space, then replaces the
    /// document wholesale.
    ///
    /// Checked *before* the write so a rejected entry never enters the store, and so the previous
    /// version survives a rejected replacement rather than being cleared for content that turns
    /// out to be unusable.
    mutating func replace(
        documentID: RTSRAGDocumentID,
        with entries: [RTSRAGStoreEntry]
    ) throws {
        try validate(entries)
        if entries.isEmpty {
            documents.removeValue(forKey: documentID)
        } else {
            documents[documentID] = entries
            embeddingModel = embeddingModel ?? entries.first?.embeddingModel
            dimension = dimension ?? entries.first?.vector.count
        }
    }

    mutating func remove(documentID: RTSRAGDocumentID) {
        documents.removeValue(forKey: documentID)
    }

    /// Replaces everything, for a file store replaying its log.
    mutating func reset(to documents: [RTSRAGDocumentID: [RTSRAGStoreEntry]]) throws {
        self = RTSRAGStoreIndex()
        for (id, entries) in documents {
            try replace(documentID: id, with: entries)
        }
    }

    // MARK: Guards

    /// Rejects anything that would make the store's vectors incomparable with each other.
    ///
    /// Two different failures, both silent if unchecked:
    ///
    /// - **A different model.** Scores across vector spaces are meaningless but well-formed, so a
    ///   mixed index returns confident nonsense rather than an error. This is what the composite
    ///   ``RTSRAGEmbedding/modelIdentifier`` — `nl-contextual/<uuid>/rev1/mean` — is *for*: a
    ///   friendly name would let a store built under different pooling pass this check.
    /// - **A different width.** Conduit's `cosineSimilarity` returns `0` on a dimension mismatch
    ///   instead of throwing, which presents as "nothing matches anything" with no indication why.
    ///   A store must not reproduce that.
    private func validate(_ entries: [RTSRAGStoreEntry]) throws {
        guard let first = entries.first else {
            return
        }
        if let embeddingModel, embeddingModel != first.embeddingModel {
            throw RTSRAGError.embeddingModelMismatch(
                expected: embeddingModel,
                found: first.embeddingModel
            )
        }
        let width = dimension ?? first.vector.count
        for entry in entries where entry.vector.count != width {
            throw RTSRAGError.storeFailed(
                reason: """
                entry \(entry.id) has a \(entry.vector.count)-dimension vector, \
                but this store holds \(width)-dimension vectors
                """
            )
        }
    }

    /// Rejects a query whose vector is the wrong width for what is stored.
    ///
    /// **Width only.** An earlier version took an `expecting model:` parameter and compared model
    /// identities too — but every caller passed `nil`, so that branch never ran, and a parameter
    /// that is permanently nil reads as protection which is not there. Removed rather than wired,
    /// because a `RTSRAGStoreQuery` does not carry the identity of the embedder that produced it
    /// and giving it one would land in the same state: an optional field, nil by default.
    ///
    /// The identity check lives in ``RTSRAGRetrievalRuntime`` instead, which is the only component
    /// that knows *both* the embedder's identity and the store's. It matters because width alone
    /// is a weak proxy: an on-device 512 and `text-embedding-3-small` truncated to 512 pass this
    /// check and mean entirely different things.
    func validateQuery(_ query: RTSRAGStoreQuery) throws {
        guard let dimension else {
            return
        }
        guard query.embedding.count == dimension else {
            throw RTSRAGError.storeFailed(
                reason: """
                query vector has \(query.embedding.count) dimensions, \
                but this store holds \(dimension)-dimension vectors
                """
            )
        }
    }

    // MARK: Reads

    /// Ranked nearest neighbours, by brute force.
    ///
    /// Every entry is compared. Exact, nothing to invalidate, and far below the embedding round
    /// trip that produced the query — an approximate index is a later decision, to be made against
    /// a corpus that can be profiled rather than guessed at.
    func search(_ query: RTSRAGStoreQuery) -> [RTSRAGRetrievedEntry] {
        let candidates = entries.filter { entry in
            matches(entry, filters: query.metadataFilters, scope: query.scope)
        }
        return candidates
            .map { (entry: $0, score: RTSRAGStoreIndex.cosine($0.vector, query.embedding)) }
            .sorted { $0.score > $1.score }
            .prefix(max(0, query.topK))
            .enumerated()
            .map { rank, hit in
                RTSRAGRetrievedEntry(entry: hit.entry, score: hit.score, rank: rank)
            }
    }

    func find(matching filters: RTSRAGMetadata, limit: Int) -> [RTSRAGStoreEntry] {
        guard limit > 0 else {
            return []
        }
        return entries
            .filter { matches($0, filters: filters, scope: nil) }
            .prefix(limit)
            .map { $0 }
    }

    func count(matching filters: RTSRAGMetadata) -> Int {
        entries.reduce(into: 0) { total, entry in
            if matches(entry, filters: filters, scope: nil) {
                total += 1
            }
        }
    }

    /// Flat equality, which is all the staleness check needs — `source_path` and `content_hash`.
    private func matches(
        _ entry: RTSRAGStoreEntry,
        filters: RTSRAGMetadata?,
        scope: RTSRAGStoreScope?
    ) -> Bool {
        if let scope, entry.scope != scope {
            return false
        }
        guard let filters else {
            return true
        }
        for (key, value) in filters where entry.metadata[key] != value {
            return false
        }
        return true
    }

    /// Cosine similarity. Returns `0` for a zero-magnitude vector, which cannot have a direction.
    ///
    /// Callers guard dimension before reaching here, so a mismatch is a programming error rather
    /// than a silent zero — the behaviour this whole guard exists to avoid.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var leftMagnitude: Float = 0
        var rightMagnitude: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftMagnitude += lhs[index] * lhs[index]
            rightMagnitude += rhs[index] * rhs[index]
        }
        let denominator = (leftMagnitude * rightMagnitude).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }
}
