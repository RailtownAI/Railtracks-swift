//
//  RTSRAGChunkAssembly.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

// MARK: - RTSRAGChunkPiece

/// One piece a chunker has decided on, before it becomes an ``RTSRAGChunk``.
///
/// Carries only what a chunker knows. Identity, ordering and the document's metadata are added by
/// ``RTSRAGChunker/makeChunks(from:pieces:)``, which is the point: a chunker says *what* the pieces
/// are and never assembles them itself.
public struct RTSRAGChunkPiece: Sendable {
    public let content: String
    /// Character offsets into the source document, for provenance and slicing.
    public let offsets: Range<Int>?
    /// Overlaid on the document's metadata. Use it for facts about this piece — a sentence count,
    /// a heading path — not for anything the document already carries.
    public let metadata: RTSRAGMetadata

    public init(
        content: String,
        offsets: Range<Int>? = nil,
        metadata: RTSRAGMetadata = [:]
    ) {
        self.content = content
        self.offsets = offsets
        self.metadata = metadata
    }
}

// MARK: - Assembly

public extension RTSRAGChunker {

    /// Turns decided pieces into chunks, applying every invariant the rest of the pipeline relies
    /// on.
    ///
    /// **Go through this rather than constructing ``RTSRAGChunk`` directly.** The invariants are
    /// not cosmetic and both of the likely mistakes fail silently:
    ///
    /// - **Dense, zero-based `index`.** It is the only ordering signal that survives storage —
    ///   entries are written under their own ids and may be reordered — so a gap or a repeat
    ///   reassembles the document wrongly with nothing to indicate it.
    /// - **`documentID` on every chunk.** It is the key `replaceDocument` clears on, so a chunk
    ///   carrying the wrong one is never replaced and never deleted: it lingers in the index,
    ///   answering queries with stale content forever.
    /// - **Document metadata inherited, then overlaid.** Filtered search reads the document's
    ///   metadata off the chunk; dropping it makes a chunk invisible to any filtered query while
    ///   still matching unfiltered ones.
    ///
    /// Python enforces the same set in `Chunker._make_chunks` and requires subclasses to route
    /// through it. This is a protocol extension rather than a base class, so conforming is enough —
    /// there is no inheritance to opt into and no question of what is overridable.
    func makeChunks(
        from document: RTSRAGDocument,
        pieces: [RTSRAGChunkPiece]
    ) -> [RTSRAGChunk] {
        pieces.enumerated().map { index, piece in
            var metadata = document.metadata
            for (key, value) in piece.metadata {
                metadata[key] = value
            }
            return RTSRAGChunk(
                content: piece.content,
                documentID: document.id,
                index: index,
                offsets: piece.offsets,
                metadata: metadata
            )
        }
    }
}
