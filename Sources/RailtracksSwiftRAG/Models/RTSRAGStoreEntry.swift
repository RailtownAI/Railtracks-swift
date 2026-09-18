//
//  RTSRAGStoreEntry.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

// MARK: - RTSRAGEmbeddedChunk

/// A chunk with its vector attached.
///
/// The embedder's output. Note the vector is `[Float]`, matching Conduit's `EmbeddingResult` —
/// embedding produces numbers, not text, and the similarity search is arithmetic over them.
public struct RTSRAGEmbeddedChunk: Sendable, Hashable, Codable {
    public let chunk: RTSRAGChunk
    public let vector: [Float]
    /// The model that produced ``vector``. Recorded on every entry so a later run can tell what
    /// built the store and refuse to query it with a different embedder — scores across models
    /// are not comparable.
    public let embeddingModel: String
    public let embeddingVersion: String?

    public init(
        chunk: RTSRAGChunk,
        vector: [Float],
        embeddingModel: String,
        embeddingVersion: String? = nil
    ) {
        self.chunk = chunk
        self.vector = vector
        self.embeddingModel = embeddingModel
        self.embeddingVersion = embeddingVersion
    }
}

// MARK: - RTSRAGStoreScope

/// A tenancy tag written onto entries and matched on reads.
///
/// Passed per ingest or retrieve call rather than fixed on the pipeline, so one configuration can
/// serve many tenants.
public struct RTSRAGStoreScope: Sendable, Hashable, Codable {
    public let labels: [String: String]

    public init(labels: [String: String]) {
        self.labels = labels
    }
}

// MARK: - RTSRAGStoreEntry

/// What a store persists: one chunk's vector, its text, and everything needed to trace it back.
///
/// The text is kept alongside the vector deliberately — the vector does the matching, the stored
/// content is what a retrieval hit hands back to be read or put in a prompt.
public struct RTSRAGStoreEntry: Sendable, Hashable, Codable {
    public let id: RTSRAGChunkID
    public let content: String
    public let vector: [Float]
    public let embeddingModel: String
    public let embeddingVersion: String?
    public let documentID: RTSRAGDocumentID
    public let chunkIndex: Int
    public let chunkOffsets: Range<Int>?
    public let parentChunkID: RTSRAGChunkID?
    public let metadata: RTSRAGMetadata
    public let scope: RTSRAGStoreScope?
    public let createdAt: Date

    public init(
        embedded: RTSRAGEmbeddedChunk,
        scope: RTSRAGStoreScope? = nil,
        createdAt: Date = Date()
    ) {
        let chunk = embedded.chunk
        self.id = chunk.id
        self.content = chunk.content
        self.vector = embedded.vector
        self.embeddingModel = embedded.embeddingModel
        self.embeddingVersion = embedded.embeddingVersion
        self.documentID = chunk.documentID
        self.chunkIndex = chunk.index
        self.chunkOffsets = chunk.offsets
        self.parentChunkID = chunk.parentChunkID
        self.metadata = chunk.metadata
        self.scope = scope
        self.createdAt = createdAt
    }
}
