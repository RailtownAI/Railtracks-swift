//
//  RTSRAGSplitter.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation
import NaturalLanguage

// MARK: - RTSRAGSplitter

/// Decides *where* a text may be cut. It does not decide what a chunk is.
///
/// That split is the reason this protocol exists. "Where may I cut?" and "how do I group cuts into
/// chunks?" vary independently — sentences, paragraphs, headings and clause numbering on one axis;
/// character budgets, overlap and hierarchy on the other — so fusing them would need a type per
/// combination. Kept apart, N splitters compose with M chunkers.
///
/// The asymmetry is what makes the seam worth a protocol: a splitter is the cheap half. A clause
/// splitter for contracts is a regex and a loop, while the grouping half is where overlap
/// arithmetic, oversized pieces and dense index assignment live. So a custom chunker is usually a
/// custom *splitter*, inheriting the tested half rather than reimplementing it.
///
/// - Returns: ranges rather than strings, which is a departure from the Python engine. Its
///   `Splitter.split` returns `list[str]`, so positions are lost and `SentenceChunker` recovers
///   them with `str.find` — a path its own docstring admits can mis-locate duplicate sentences and
///   which silently guesses an offset when the lookup fails. Ranges make
///   ``RTSRAGChunk/offsets`` exact by construction and delete the fallback.
public protocol RTSRAGSplitter: Sendable {
    /// Ranges of `text` that may become chunk boundaries — in order, non-overlapping, and each
    /// slicing back to exactly the piece it names.
    ///
    /// Whitespace *between* pieces need not be covered; a chunker that joins several pieces slices
    /// the original text across them, so separators survive in the chunk's content.
    func split(_ text: String) -> [Range<String.Index>]
}

// MARK: - RTSRAGSentenceSplitter

/// Sentence boundaries, from `NaturalLanguage`'s tokenizer.
///
/// **Not a port of Python's regex.** Its detector is `(?<=[.!?])\s+`, which breaks on `Dr. Smith`,
/// `3.14`, `e.g. ` and every decimal in a financial document — its own docstring concedes this and
/// suggests injecting `pysbd` or spaCy.
///
/// **And not Foundation's `.bySentences` either, which was the first choice here and is measurably
/// worse:** `enumerateSubstrings(in:options: [.bySentences])` splits `"Dr. Smith owed 3.14
/// dollars."` into `["Dr.", "Smith owed 3.14 dollars."]`, so it fails on abbreviations much as the
/// regex does. `NLTokenizer(unit: .sentence)` keeps it whole. Measured, not assumed — a test pins
/// exactly this string.
///
/// `NaturalLanguage` is a system framework on every platform this package targets, so the better
/// segmenter costs no dependency.
///
/// - Note: a period followed by a *lowercase* letter is not a boundary to either segmenter —
///   `"one. two."` is one sentence, because that shape is far more often an abbreviation than a
///   sentence break. Text that has lost its capitalisation chunks as a single unit, and needs a
///   custom ``RTSRAGSplitter`` rather than a tuning knob.
public struct RTSRAGSentenceSplitter: RTSRAGSplitter {

    private let splitsOnLowercaseStart: Bool

    /// - Parameter splitsOnLowercaseStart: also break after `.`, `!` or `?` when the next sentence
    ///   begins in lowercase. Off by default.
    ///
    ///   This is the knob for "tolerate imperfect text rather than insist on grammar", and the
    ///   trade runs both ways, which is why it is a choice and not the default:
    ///
    ///   - **Off** — `Dr. Smith owed 3.14 dollars.` stays whole, and so does a whole lowercase
    ///     transcript, which then has to be cut by the chunker's fallback instead.
    ///   - **On** — a lowercase transcript gets real sentence boundaries, and `Dr. Smith` splits
    ///     after `Dr.` exactly as Python's regex does.
    ///
    ///   Pick per corpus. Prose, reports and documentation want it off; chat logs, transcripts,
    ///   OCR output and user-generated text usually want it on. A corpus with both wants two
    ///   ingests, which costs nothing because the chunker is chosen per `ingest` call.
    public init(splitsOnLowercaseStart: Bool = false) {
        self.splitsOnLowercaseStart = splitsOnLowercaseStart
    }

    public func split(_ text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else {
            return []
        }
        // Built per call rather than stored: `NLTokenizer` is a reference type whose `string` is
        // mutated to tokenize, so a shared instance would neither be `Sendable` nor safe to reuse.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Tokens carry their trailing whitespace, and a run of blank lines comes through as a
            // token of its own. Trimming makes offsets slice back to exactly the sentence and drops
            // the whitespace-only tokens; separators are picked up by the chunker when it slices
            // across several sentences.
            if let trimmed = text.rtsRAGTrimmingWhitespace(range) {
                ranges.append(trimmed)
            }
            return true
        }
        guard splitsOnLowercaseStart else {
            return ranges
        }
        return ranges.flatMap { splitAtTerminators($0, in: text) }
    }

    /// Breaks a range after every `.`, `!` or `?` that is followed by whitespace, whatever case
    /// comes next.
    ///
    /// Applied *after* the tokenizer rather than instead of it, so everything the tokenizer already
    /// got right about line breaks and quotation stays, and only the case rule is relaxed.
    private func splitAtTerminators(
        _ range: Range<String.Index>,
        in text: String
    ) -> [Range<String.Index>] {
        var parts: [Range<String.Index>] = []
        var start = range.lowerBound
        var index = range.lowerBound
        while index < range.upperBound {
            let next = text.index(after: index)
            let isTerminator = text[index] == "." || text[index] == "!" || text[index] == "?"
            let endsPiece = isTerminator && (next == range.upperBound || text[next].isWhitespace)
            if endsPiece {
                if let trimmed = text.rtsRAGTrimmingWhitespace(start..<next) {
                    parts.append(trimmed)
                }
                start = next
            }
            index = next
        }
        if let trimmed = text.rtsRAGTrimmingWhitespace(start..<range.upperBound) {
            parts.append(trimmed)
        }
        return parts
    }

}

// MARK: - Shared trimming

internal extension String {
    /// `range` with whitespace removed from both ends, or `nil` when nothing else remains.
    ///
    /// Both ends, because a piece that begins after a sentence terminator starts on the separating
    /// space. Shared by the splitter and the chunker, so every range either slices back to real
    /// content or is dropped — which is what keeps ``RTSRAGChunk/offsets`` meaningful.
    func rtsRAGTrimmingWhitespace(_ range: Range<String.Index>) -> Range<String.Index>? {
        var start = range.lowerBound
        while start < range.upperBound, self[start].isWhitespace {
            start = index(after: start)
        }
        var end = range.upperBound
        while end > start {
            let previous = index(before: end)
            guard self[previous].isWhitespace else {
                break
            }
            end = previous
        }
        guard end > start else {
            return nil
        }
        return start..<end
    }
}
