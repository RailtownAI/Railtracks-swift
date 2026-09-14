//
//  RTSRAGLimits.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

/// Size limits for the ingest pipeline.
public enum RTSRAGLimits {
    /// Maximum characters a chunker may emit in one chunk.
    ///
    /// **Characters, not tokens, and that is the point.** A chunker enforces this by
    /// construction, so an oversized chunk becomes impossible rather than something to detect —
    /// which removes the need for a token counter that Swift has no accurate implementation of.
    /// The Python engine needs its `max_tokens` guard because chunkers like its semantic one emit
    /// variable-size output that has to be measured after the fact.
    ///
    /// The arithmetic holds for any realistic corpus: tokens run about a quarter of characters
    /// for English prose, roughly 1:1 for dense code and CJK, and a few per character only for
    /// emoji-heavy text. 1,024 characters therefore lands somewhere between ~256 and ~4,000
    /// tokens — comfortably under ``maxEmbeddingInputTokens`` in every case.
    ///
    /// This is also a retrieval-quality knob, not only a safety one: too small and a chunk lacks
    /// the context to answer anything, too large and its embedding blurs across topics. Expect to
    /// tune it against a real corpus.
    public static let defaultMaxChunkCharacters = 1024

    /// The embedding provider's input ceiling, in tokens. 8191 for `text-embedding-3-*`.
    ///
    /// A constant for now. It becomes a computed property over provider and model once more than
    /// one embedder exists — the value is a property of the model, not of this library.
    public static let maxEmbeddingInputTokens = 8191
}
