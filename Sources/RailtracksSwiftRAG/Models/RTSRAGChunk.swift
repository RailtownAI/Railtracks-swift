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

// MARK: - Positional identity

public extension RTSRAGChunk {
    /// `"<documentID>#<index>"` — an identifier that survives re-ingest, unlike ``id``.
    ///
    /// ``id`` is a fresh random UUID on every ingest, which nothing in this module minds: stores
    /// replace whole documents, and the staleness check never reads chunk ids. What it breaks is an
    /// index *outside* the store that remembers chunks by id, such as Spotlight, which would lose
    /// every item on each update. The document id is derived from the source and the index is the
    /// chunk's position, so this stays the same as long as the chunker splits the same way.
    ///
    /// Computed rather than stored, so ``id``, the stored fields and the file store's log format
    /// are unchanged.
    var positionalIdentifier: String {
        "\(documentID)#\(index)"
    }
}

// MARK: - Stamping

extension RTSRAGChunk {
    /// Writes the staleness metadata every later run reads back: the document's source and
    /// content hash.
    ///
    /// Shared by both runtimes so they stamp alike — the staleness check reads these keys back as
    /// filters, so a writer that spelled them differently would never find its own documents.
    static func stamped(_ chunks: [RTSRAGChunk], from document: RTSRAGDocument) -> [RTSRAGChunk] {
        chunks.map { chunk in
            var chunk = chunk
            if let source = document.source {
                chunk.metadata[RTSRAGChunk.MetadataKey.sourcePath] = .string(source)
            }
            if let hash = document.contentHash {
                chunk.metadata[RTSRAGChunk.MetadataKey.contentHash] = .string(hash)
            }
            return chunk
        }
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
