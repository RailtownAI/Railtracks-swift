//
//  RTSRAGIdentityChunker.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

/// Emits the whole document as one chunk.
///
/// **Not a placeholder — often the correct choice.** A CSV row, a JSON record and a short PDF page
/// arrive already chunk-sized, because the loader made the document boundary the record boundary.
/// Splitting them again strands a row's columns across two embeddings and degrades retrieval for
/// no gain, so this is the right pairing for every loader that emits one document per record.
///
/// Also the baseline to compare a splitting strategy against, since it is the only chunker that
/// cannot be blamed for a boundary.
///
/// - Important: it performs no size check, so a document over
///   ``RTSRAGLimits/defaultMaxChunkCharacters`` produces an oversized chunk. That is the one place
///   the module's "oversized chunks are impossible by construction" guarantee rests on the caller
///   rather than on the code: pair it with loaders whose documents are records, not with prose.
public struct RTSRAGIdentityChunker: RTSRAGChunker {

    public init() {
    }

    public func chunk(_ document: RTSRAGDocument) async throws -> [RTSRAGChunk] {
        let text = document.content
        // Empty content yields nothing rather than one empty chunk — consistent with every other
        // chunker, and an empty string would otherwise be embedded and stored as a hit that can
        // never be useful.
        guard !text.isEmpty else {
            return []
        }
        return makeChunks(
            from: document,
            pieces: [RTSRAGChunkPiece(content: text, offsets: 0..<text.count)]
        )
    }
}
