//
//  RTSRAGInMemoryStore.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-18.
//

import Foundation

/// A store that keeps everything in memory and nothing on disk.
///
/// The default for tests and for a corpus small enough to rebuild on launch. It is not a toy: the
/// search, the filtering and the vector-space guards are the same code ``RTSRAGFileStore`` runs, so
/// behaviour cannot drift between them — the file store adds durability and nothing else.
///
/// ## One embedder per store
///
/// Holds vectors from exactly one embedding model and one width, both taken from the first write.
/// A write from a different model throws ``RTSRAGError/embeddingModelMismatch(expected:found:)``;
/// a different width throws ``RTSRAGError/storeFailed(reason:)``. Emptying the store clears both,
/// so it can then be reused with any embedder. Several embedders means several stores.
///
/// An `actor` because a store is shared mutable state. That also serialises writes, which is what
/// the per-document ordering rule wants: local writes are microseconds against an embedding round
/// trip of hundreds of milliseconds, so there is no throughput to win by allowing concurrency here
/// and a correctness property to lose.
public actor RTSRAGInMemoryStore: RTSRAGVectorStore {

    private var index = RTSRAGStoreIndex()

    public init() {
    }

    public func replaceDocument(
        id: RTSRAGDocumentID,
        with entries: [RTSRAGStoreEntry]
    ) async throws {
        try index.replace(documentID: id, with: entries)
    }

    public func deleteDocument(id: RTSRAGDocumentID) async throws {
        index.remove(documentID: id)
    }

    public func search(_ query: RTSRAGStoreQuery) async throws -> [RTSRAGRetrievedEntry] {
        try index.validateQuery(query)
        return index.search(query)
    }

    public func find(
        matching filters: RTSRAGMetadata,
        limit: Int
    ) async throws -> [RTSRAGStoreEntry] {
        index.find(matching: filters, limit: limit)
    }

    public func count(matching filters: RTSRAGMetadata) async throws -> Int {
        index.count(matching: filters)
    }

    public func documents(
        under root: RTSRAGSourceRoot,
        scope: RTSRAGStoreScope?
    ) async throws -> [RTSRAGDocumentID: String] {
        index.documents(under: root, scope: scope)
    }
}
