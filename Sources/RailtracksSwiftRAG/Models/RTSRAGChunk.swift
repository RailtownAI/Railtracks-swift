//
//  RTSRAGChunk.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

// MARK: - RTSRAGChunkID

public struct RTSRAGChunkID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

// MARK: - RTSRAGChunk

/// One piece of a document, as produced by a chunker and embedded as a unit.
///
/// Ordering lives in ``index``, not in the order chunks are written. Each chunk is stored under
/// its own id, so writes can be reordered or parallelised freely — a consumer reassembling a
/// document sorts by `index`.
public struct RTSRAGChunk: Sendable, Hashable, Codable {
    public let id: RTSRAGChunkID
    public let content: String
    public let documentID: RTSRAGDocumentID
    /// Position within the document, from zero. The only ordering signal that survives storage.
    public let index: Int
    /// Character range within the source document, for provenance and offset-based slicing.
    public let offsets: Range<Int>?
    /// The chunk this was split from, when a chunker works hierarchically.
    public let parentChunkID: RTSRAGChunkID?
    /// Carries the document's metadata plus whatever the pipeline stamps on: the source path and
    /// content hash used for staleness checks, and the document's total chunk count.
    public var metadata: RTSRAGMetadata

    public init(
        id: RTSRAGChunkID = RTSRAGChunkID(),
        content: String,
        documentID: RTSRAGDocumentID,
        index: Int = 0,
        offsets: Range<Int>? = nil,
        parentChunkID: RTSRAGChunkID? = nil,
        metadata: RTSRAGMetadata = [:]
    ) {
        self.id = id
        self.content = content
        self.documentID = documentID
        self.index = index
        self.offsets = offsets
        self.parentChunkID = parentChunkID
        self.metadata = metadata
    }
}

// MARK: - Stamped metadata keys

public extension RTSRAGChunk {
    /// Metadata keys the ingest pipeline writes onto every chunk.
    ///
    /// Named rather than inlined because the staleness check reads them back as filters, so the
    /// writer and the reader have to agree on the spelling.
    enum MetadataKey {
        /// The document's ``RTSRAGDocument/source``.
        public static let sourcePath = "source_path"
        /// The document's ``RTSRAGDocument/contentHash``.
        public static let contentHash = "content_hash"
        /// How many chunks the document produced in total.
        ///
        /// Every chunk carries the same number, so reading any one persisted chunk reveals how
        /// many were expected — which is what distinguishes a document that is fully stored from
        /// one left partial by an interrupted ingest. Without it, a partial document would be
        /// mistaken for a complete one and skipped forever.
        public static let documentChunkCount = "doc_chunk_count"
    }
}
