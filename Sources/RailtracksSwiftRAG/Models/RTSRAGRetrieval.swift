//
//  RTSRAGRetrieval.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

// MARK: - RTSRAGStoreQuery

/// A similarity search against a store.
///
/// Carries the query's vector rather than its text, because embedding is the pipeline's job, not
/// the store's — a store never needs to know which provider produced the numbers it compares.
public struct RTSRAGStoreQuery: Sendable {
    public let text: String
    public let embedding: [Float]
    public let topK: Int
    /// Flat equality filters over chunk metadata.
    public let metadataFilters: RTSRAGMetadata?
    /// Restricts the search to entries written with the same scope. `nil` searches every scope.
    public let scope: RTSRAGStoreScope?

    public init(
        text: String,
        embedding: [Float],
        topK: Int = 5,
        metadataFilters: RTSRAGMetadata? = nil,
        scope: RTSRAGStoreScope? = nil
    ) {
        self.text = text
        self.embedding = embedding
        self.topK = topK
        self.metadataFilters = metadataFilters
        self.scope = scope
    }
}

// MARK: - RTSRAGRetrievedEntry

/// One store hit, with its similarity score and position.
public struct RTSRAGRetrievedEntry: Sendable {
    public let entry: RTSRAGStoreEntry
    /// Higher is more similar. Comparable only among results from the same query, and only when
    /// every entry was embedded by the same model.
    public let score: Float
    /// Position in the result list, from zero.
    public let rank: Int

    public init(
        entry: RTSRAGStoreEntry,
        score: Float,
        rank: Int
    ) {
        self.entry = entry
        self.score = score
        self.rank = rank
    }
}

// MARK: - RTSRAGRetrievalResult

/// The answer to one retrieval call: the query and its ranked hits.
public struct RTSRAGRetrievalResult: Sendable {
    public let query: String
    /// Ordered best-first. Note that identical content ingested under two different sources
    /// produces two hits with near-identical scores — deduplication is by source identity, not by
    /// content, so provenance survives at the cost of result diversity.
    public let entries: [RTSRAGRetrievedEntry]

    public init(
        query: String,
        entries: [RTSRAGRetrievedEntry]
    ) {
        self.query = query
        self.entries = entries
    }
}
