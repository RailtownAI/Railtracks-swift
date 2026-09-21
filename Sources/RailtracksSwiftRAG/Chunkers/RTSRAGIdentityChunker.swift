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
/// "Record-sized" is an assumption about the data, not a guarantee, which is why ``maxCharacters``
/// exists: a JSON object with a long `description`, or a CSV cell holding a whole paragraph, is a
/// record by structure and prose by length.
public struct RTSRAGIdentityChunker: RTSRAGChunker {

    private let maxCharacters: Int?

    /// - Parameter maxCharacters: reject a document longer than this rather than emit a chunk the
    ///   embedder will refuse. `nil` — the default — performs no check, which is right when the
    ///   embedder has headroom to spare: `text-embedding-3-*` accepts 8,191 tokens, so nothing a
    ///   record loader produces will trouble it.
    ///
    ///   Set it from the embedder's ``RTSRAGEmbedding/maxInputCharacters`` when the embedder has a
    ///   tight window. **Failing here rather than at embed time is the point**: it names the right
    ///   phase, costs no request, and says what to do about it — whereas the same document reaching
    ///   an embedder comes back as an opaque provider rejection.
    ///
    ///   Not splitting instead, because splitting is exactly what this chunker exists not to do. A
    ///   record too large to embed whole needs a different chunker for that source, and that is a
    ///   decision for the caller rather than a silent fallback.
    public init(maxCharacters: Int? = nil) {
        self.maxCharacters = maxCharacters
    }

    public func chunk(_ document: RTSRAGDocument) async throws -> [RTSRAGChunk] {
        let text = document.content
        // Empty content yields nothing rather than one empty chunk — consistent with every other
        // chunker, and an empty string would otherwise be embedded and stored as a hit that can
        // never be useful.
        guard !text.isEmpty else {
            return []
        }
        let chunks = makeChunks(
            from: document,
            pieces: [RTSRAGChunkPiece(content: text, offsets: 0..<text.count)]
        )
        if let maxCharacters, text.count > maxCharacters, let chunk = chunks.first {
            throw RTSRAGError.chunkTooLarge(
                chunkID: chunk.id,
                characters: text.count,
                limit: maxCharacters
            )
        }
        return chunks
    }
}
