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
        try index.validateQuery(query, expecting: nil)
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
}
