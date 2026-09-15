//
//  RTSRAGSentenceChunker.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

/// Packs consecutive sentences into chunks up to a character budget, with sentence overlap.
///
/// **Sentences decide where to cut; characters decide how many to take.** That combination is the
/// point, and it is where this departs from Python's `SentenceChunker`, which counts *sentences*
/// (`chunk_size=5` means five, whether that is 200 characters or 10,000) and never measures
/// length. Unbounded chunk size is exactly what ``RTSRAGLimits`` exists to make impossible — Python
/// can afford it because `max_tokens` and tiktoken catch the overflow afterwards, and this module
/// deliberately has neither.
///
/// So boundaries land between sentences, never mid-word — plain character chunking's real failing —
/// while size stays bounded by construction.
public struct RTSRAGSentenceChunker: RTSRAGChunker {

    /// Metadata this chunker stamps on the chunks it produces.
    public enum MetadataKey {
        /// How many sentences the chunk contains. Matches Python's `sentence_count`.
        public static let sentenceCount = "sentence_count"
        /// Present and `true` only on a chunk produced by hard-splitting one oversized sentence.
        ///
        /// Stamped so the one case sentence boundaries cannot honour is visible in the data rather
        /// than inferred from a chunk that happens to end mid-word.
        public static let hardSplit = "hard_split"
    }

    private let maxCharacters: Int
    private let overlapSentences: Int
    private let splitter: any RTSRAGSplitter

    /// - Parameters:
    ///   - maxCharacters: Upper bound on a chunk's length. Defaults to
    ///     ``RTSRAGLimits/defaultMaxChunkCharacters``.
    ///   - overlapSentences: Sentences shared between adjacent chunks, so a passage split across a
    ///     boundary is still wholly present in one of them. `0` disables overlap.
    ///   - splitter: Where sentences begin and end. Swap it to chunk on paragraphs, headings or
    ///     clause numbering without reimplementing the packing.
    public init(
        maxCharacters: Int = RTSRAGLimits.defaultMaxChunkCharacters,
        overlapSentences: Int = 1,
        splitter: any RTSRAGSplitter = RTSRAGSentenceSplitter()
    ) {
        precondition(maxCharacters > 0, "maxCharacters must be greater than 0")
        precondition(overlapSentences >= 0, "overlapSentences must be 0 or more")
        self.maxCharacters = maxCharacters
        self.overlapSentences = overlapSentences
        self.splitter = splitter
    }

    public func chunk(_ document: RTSRAGDocument) async throws -> [RTSRAGChunk] {
        let text = document.content
        guard !text.isEmpty else {
            return []
        }
        let sentences = offsetSentences(in: text)
        guard !sentences.isEmpty else {
            return []
        }
        return makeChunks(from: document, pieces: pack(sentences, in: text))
    }

    // MARK: - Packing

    /// A sentence, with both the index range needed to slice it and the character offsets recorded
    /// on the chunk.
    private struct Sentence {
        let range: Range<String.Index>
        let offsets: Range<Int>
    }

    /// Converts the splitter's index ranges into character offsets in one pass.
    ///
    /// Walked cumulatively rather than calling `distance(from: startIndex,…)` per range: that is
    /// O(n) each, so a document of many sentences would be O(n²).
    private func offsetSentences(in text: String) -> [Sentence] {
        var sentences: [Sentence] = []
        var cursor = text.startIndex
        var offset = 0
        for range in splitter.split(text) {
            offset += text.distance(from: cursor, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            sentences.append(Sentence(range: range, offsets: offset..<(offset + length)))
            offset += length
            cursor = range.upperBound
        }
        return sentences
    }

    private func pack(_ sentences: [Sentence], in text: String) -> [RTSRAGChunkPiece] {
        var pieces: [RTSRAGChunkPiece] = []
        var start = 0
        while start < sentences.count {
            let first = sentences[start]
            // A single sentence over the budget cannot be honoured by sentence boundaries at all,
            // so it is cut on characters and marked. Rare in prose, reachable in minified data or
            // an unpunctuated transcript.
            if first.offsets.count > maxCharacters {
                pieces.append(contentsOf: hardSplit(first, in: text))
                start += 1
                continue
            }
            var end = start
            while end + 1 < sentences.count {
                let candidate = first.offsets.lowerBound..<sentences[end + 1].offsets.upperBound
                guard candidate.count <= maxCharacters else {
                    break
                }
                end += 1
            }
            // Sliced across the whole window rather than joined, so the separators between
            // sentences survive exactly as the document had them.
            let span = first.range.lowerBound..<sentences[end].range.upperBound
            pieces.append(
                RTSRAGChunkPiece(
                    content: String(text[span]),
                    offsets: first.offsets.lowerBound..<sentences[end].offsets.upperBound,
                    metadata: [MetadataKey.sentenceCount: .integer(end - start + 1)]
                )
            )
            guard end + 1 < sentences.count else {
                break
            }
            // `start + 1` floors the step: with an overlap wide enough to swallow the window, the
            // next start would otherwise not advance and this would not terminate.
            start = max(start + 1, end + 1 - overlapSentences)
        }
        return pieces
    }

    private func hardSplit(_ sentence: Sentence, in text: String) -> [RTSRAGChunkPiece] {
        var pieces: [RTSRAGChunkPiece] = []
        var pieceStart = sentence.range.lowerBound
        var offset = sentence.offsets.lowerBound
        while pieceStart < sentence.range.upperBound {
            let limit = text.index(
                pieceStart,
                offsetBy: maxCharacters,
                limitedBy: sentence.range.upperBound
            ) ?? sentence.range.upperBound
            // Back off to the last word boundary before the limit. Cutting on characters is the
            // terminal fallback, but landing mid-word is gratuitous: a half-word contributes
            // nothing to the embedding and the two halves each match worse than the whole would.
            // Only a single word longer than the budget still cuts mid-word.
            let pieceEnd = limit < sentence.range.upperBound
                ? Self.lastWordBoundary(before: limit, notBefore: pieceStart, in: text) ?? limit
                : limit
            let length = text.distance(from: pieceStart, to: pieceEnd)
            pieces.append(
                RTSRAGChunkPiece(
                    content: String(text[pieceStart..<pieceEnd]),
                    offsets: offset..<(offset + length),
                    metadata: [
                        MetadataKey.sentenceCount: .integer(1),
                        MetadataKey.hardSplit: .boolean(true),
                    ]
                )
            )
            pieceStart = pieceEnd
            offset += length
            // Whitespace at the cut belongs to neither side; skipping it keeps the next piece from
            // opening with a space and keeps offsets aligned with content.
            while pieceStart < sentence.range.upperBound, text[pieceStart].isWhitespace {
                pieceStart = text.index(after: pieceStart)
                offset += 1
            }
        }
        return pieces
    }

    /// The position just after the last non-whitespace run that ends before `limit`, or `nil` when
    /// the piece holds no whitespace to break on — a single word longer than the budget.
    private static func lastWordBoundary(
        before limit: String.Index,
        notBefore start: String.Index,
        in text: String
    ) -> String.Index? {
        var index = limit
        while index > start {
            let previous = text.index(before: index)
            if text[previous].isWhitespace {
                return previous
            }
            index = previous
        }
        return nil
    }
}
