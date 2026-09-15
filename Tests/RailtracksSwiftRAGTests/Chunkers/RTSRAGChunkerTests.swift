//
//  RTSRAGChunkerTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// Phase 3 of the RAG port: chunkers, the splitter seam, and the invariants every chunk carries.
@Suite("RailtracksSwiftRAG chunkers")
struct RTSRAGChunkerTests {

    // MARK: - Sentence detection

    @Test("abbreviations and decimals are not sentence boundaries")
    func sentenceSplitterHandlesAmbiguousPeriods() {
        let text = "Dr. Smith owed 3.14 dollars. He paid, e.g. in cash. Done."
        let ranges = RTSRAGSentenceSplitter().split(text)

        // The reason Foundation's ICU segmentation is used instead of porting Python's
        // `(?<=[.!?])\s+`: that regex breaks after "Dr.", "3.", and "e.g." — six pieces instead of
        // three — and its own docstring concedes the weakness. Every period here is ambiguous.
        #expect(ranges.count == 3)
        #expect(String(text[ranges[0]]) == "Dr. Smith owed 3.14 dollars.")
        #expect(String(text[ranges[2]]) == "Done.")
    }

    @Test("a split range slices back to exactly its sentence")
    func sentenceRangesAreExact() {
        let text = "First one.   Second one.\n\nThird one."
        let ranges = RTSRAGSentenceSplitter().split(text)

        // Trailing whitespace is trimmed from each range, so offsets recorded on a chunk slice
        // back to the text they name. Inter-sentence whitespace is left uncovered deliberately —
        // a chunker slicing across sentences picks it up from the original.
        #expect(ranges.map { String(text[$0]) } == ["First one.", "Second one.", "Third one."])
    }

    @Test("an empty document yields no sentences and no chunks")
    func emptyContentYieldsNothing() async throws {
        #expect(RTSRAGSentenceSplitter().split("").isEmpty)

        let document = RTSRAGDocument(content: "", source: "file:///empty.txt")
        let chunks = try await RTSRAGSentenceChunker().chunk(document)
        let identity = try await RTSRAGIdentityChunker().chunk(document)

        #expect(chunks.isEmpty)
        #expect(identity.isEmpty)
    }

    // MARK: - Packing

    @Test("sentences pack up to the character budget, not to a sentence count")
    func packingRespectsCharacterBudget() async throws {
        // Four nine-character sentences plus separators. A budget of 19 fits exactly two.
        // Capitalised deliberately: a period followed by a lowercase letter is not a sentence
        // boundary to any real segmenter, so `"aaa. bbb."` would arrive here as one sentence.
        let text = "Aaaaaaaa. Bbbbbbbb. Cccccccc. Dddddddd."
        let document = RTSRAGDocument(content: text, source: "file:///a.txt")
        let chunker = RTSRAGSentenceChunker(maxCharacters: 19, overlapSentences: 0)

        let chunks = try await chunker.chunk(document)

        // Python's SentenceChunker would take a fixed *count* of sentences here and let the
        // character length fall where it may. Budgeting instead is what keeps an oversized chunk
        // impossible without a token counter.
        #expect(chunks.allSatisfy { $0.content.count <= 19 })
        #expect(chunks.count == 2)
        #expect(chunks[0].content == "Aaaaaaaa. Bbbbbbbb.")
        #expect(chunks[1].content == "Cccccccc. Dddddddd.")
    }

    @Test("overlap repeats the trailing sentences of the previous chunk")
    func overlapSharesSentences() async throws {
        let text = "Aaaaaaaa. Bbbbbbbb. Cccccccc. Dddddddd."
        let document = RTSRAGDocument(content: text, source: "file:///a.txt")
        let chunker = RTSRAGSentenceChunker(maxCharacters: 19, overlapSentences: 1)

        let chunks = try await chunker.chunk(document)

        // Overlap exists so a passage straddling a boundary is wholly present somewhere. Without
        // it, a question answered by the last line of one chunk and the first of the next matches
        // neither well.
        #expect(chunks.count == 3)
        #expect(chunks[0].content == "Aaaaaaaa. Bbbbbbbb.")
        #expect(chunks[1].content == "Bbbbbbbb. Cccccccc.")
        #expect(chunks[2].content == "Cccccccc. Dddddddd.")
        #expect(chunks.allSatisfy { $0.content.count <= 19 })
    }

    @Test("an overlap wider than the window still terminates")
    func oversizedOverlapMakesProgress() async throws {
        let text = "Aaaaaaaa. Bbbbbbbb. Cccccccc. Dddddddd."
        let document = RTSRAGDocument(content: text, source: "file:///a.txt")
        // Each window holds two sentences, so an overlap of 5 would rewind past the window start
        // and the packer would never advance. The step is floored at one sentence for exactly this.
        let chunker = RTSRAGSentenceChunker(maxCharacters: 19, overlapSentences: 5)

        let chunks = try await chunker.chunk(document)

        #expect(!chunks.isEmpty)
        #expect(chunks.count <= 4)
    }

    @Test("a single sentence over the budget is hard split and marked")
    func oversizedSentenceIsHardSplit() async throws {
        let long = String(repeating: "x", count: 50)
        let document = RTSRAGDocument(content: "\(long). Short one.", source: "file:///a.txt")
        let chunker = RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)

        let chunks = try await chunker.chunk(document)

        // The one case sentence boundaries cannot honour. It is stamped rather than left to be
        // inferred from a chunk that happens to end mid-word.
        #expect(chunks.allSatisfy { $0.content.count <= 20 })
        let hardSplit = chunks.filter {
            $0.metadata[RTSRAGSentenceChunker.MetadataKey.hardSplit] == .boolean(true)
        }
        #expect(hardSplit.count == 3)
        #expect(chunks.last?.content == "Short one.")
        #expect(chunks.last?.metadata[RTSRAGSentenceChunker.MetadataKey.hardSplit] == nil)
    }

    @Test("a hard split backs off to a word boundary")
    func hardSplitAvoidsCuttingWords() async throws {
        let text = "Alpha bravo charlie delta echo foxtrot golf hotel."
        let document = RTSRAGDocument(content: text, source: "file:///a.txt")

        let chunks = try await RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)
            .chunk(document)

        // One sentence over budget still has to be cut, but landing mid-word is gratuitous: half a
        // word contributes nothing to the embedding and both halves match worse than the whole.
        // Characters are the terminal fallback, reached only by a single word over the budget.
        #expect(chunks.map { $0.content } == [
            "Alpha bravo charlie",
            "delta echo foxtrot",
            "golf hotel.",
        ])
        #expect(chunks.allSatisfy { $0.content.count <= 20 })

        // Whitespace at a cut belongs to neither side, so offsets must stay aligned after skipping.
        let characters = Array(text)
        for chunk in chunks {
            let offsets = try #require(chunk.offsets)
            #expect(String(characters[offsets]) == chunk.content)
        }
    }

    @Test("lowercase sentence starts split only when the splitter is asked to")
    func lowercaseStartsAreOptIn() {
        let text = "one thing happened. another thing happened. done."

        let strict = RTSRAGSentenceSplitter().split(text)
        let lenient = RTSRAGSentenceSplitter(splitsOnLowercaseStart: true).split(text)

        // Strict is the default because relaxing the case rule costs the common case: with the flag
        // on, `Dr. Smith` splits after `Dr.` exactly as Python's regex does. Corpora that have lost
        // their capitalisation — transcripts, chat logs, OCR — opt in per ingest.
        #expect(strict.count == 1)
        #expect(lenient.map { String(text[$0]) } == [
            "one thing happened.",
            "another thing happened.",
            "done.",
        ])

        let lenientOnProse = RTSRAGSentenceSplitter(splitsOnLowercaseStart: true)
            .split("Dr. Smith paid.")
        #expect(lenientOnProse.count == 2)
    }

    // MARK: - Invariants

    @Test("index is dense and zero-based across every chunk")
    func indexIsDense() async throws {
        let text = (0..<12).map { "Sentence number \($0)." }.joined(separator: " ")
        let document = RTSRAGDocument(content: text, source: "file:///a.txt")

        let chunks = try await RTSRAGSentenceChunker(maxCharacters: 40).chunk(document)

        // The only ordering signal that survives storage — entries are written under their own ids
        // and may be reordered — so a gap or repeat reassembles the document wrongly and silently.
        #expect(chunks.map { $0.index } == Array(0..<chunks.count))
    }

    @Test("offsets slice back to exactly the chunk content")
    func offsetsAreAccurate() async throws {
        let text = "First sentence here. Second sentence here. Third sentence here."
        let document = RTSRAGDocument(content: text, source: "file:///a.txt")

        let chunks = try await RTSRAGSentenceChunker(maxCharacters: 45).chunk(document)
        let characters = Array(text)

        for chunk in chunks {
            let offsets = try #require(chunk.offsets)
            #expect(String(characters[offsets]) == chunk.content)
        }
    }

    @Test("chunks inherit document metadata and overlay their own")
    func metadataIsInherited() async throws {
        let document = RTSRAGDocument(
            content: "One sentence. Two sentence.",
            source: "file:///a.txt",
            metadata: ["jurisdiction": .string("TX"), "revision": .integer(3)]
        )

        let chunks = try await RTSRAGSentenceChunker(maxCharacters: 200).chunk(document)

        // Filtered search reads the document's metadata off the chunk, so dropping it makes a chunk
        // invisible to any filtered query while still matching unfiltered ones — a failure that
        // looks like bad relevance rather than a bug.
        let chunk = try #require(chunks.first)
        #expect(chunk.metadata["jurisdiction"] == .string("TX"))
        #expect(chunk.metadata["revision"] == .integer(3))
        #expect(chunk.metadata[RTSRAGSentenceChunker.MetadataKey.sentenceCount] == .integer(2))
        #expect(chunk.documentID == document.id)
    }

    @Test("a piece's metadata does not leak into its siblings")
    func metadataIsNotSharedBetweenChunks() async throws {
        let text = "Aaaaaaaa. Bbbbbbbb. Cccccccc."
        let document = RTSRAGDocument(content: text, source: "file:///a.txt", metadata: ["k": .integer(1)])

        let chunks = try await RTSRAGSentenceChunker(maxCharacters: 19, overlapSentences: 0)
            .chunk(document)

        // Python copies the document's metadata per chunk for this reason; a shared dictionary
        // would let one chunk's `sentence_count` overwrite every other chunk's.
        #expect(chunks.count == 2)
        #expect(chunks[0].metadata[RTSRAGSentenceChunker.MetadataKey.sentenceCount] == .integer(2))
        #expect(chunks[1].metadata[RTSRAGSentenceChunker.MetadataKey.sentenceCount] == .integer(1))
        #expect(chunks.allSatisfy { $0.metadata["k"] == .integer(1) })
    }

    // MARK: - Identity chunker

    @Test("the identity chunker emits the whole document as one chunk")
    func identityChunkerPassesThrough() async throws {
        let text = "A row: Alice\nage: 30"
        let document = RTSRAGDocument(
            content: text,
            type: .csv,
            source: "file:///a.csv#4",
            metadata: ["row_index": .integer(4)]
        )

        let chunks = try await RTSRAGIdentityChunker().chunk(document)

        // The right pairing for loaders that already emit one document per record — splitting a
        // CSV row again strands its columns across two embeddings.
        #expect(chunks.count == 1)
        #expect(chunks[0].content == text)
        #expect(chunks[0].index == 0)
        #expect(chunks[0].offsets == 0..<text.count)
        #expect(chunks[0].metadata["row_index"] == .integer(4))
    }

    // MARK: - Custom splitter

    @Test("a custom splitter changes boundaries without touching the packing")
    func customSplitterComposes() async throws {
        let text = "1.1 First clause 1.2 Second clause 1.3 Third clause"
        let document = RTSRAGDocument(content: text, source: "file:///contract.txt")

        let chunks = try await RTSRAGSentenceChunker(
            maxCharacters: 20,
            overlapSentences: 0,
            splitter: ClauseSplitter()
        ).chunk(document)

        // The seam's whole purpose: a domain splitter is a few lines and inherits packing, overlap,
        // dense indexing and offsets. ICU would see one sentence here and give one chunk.
        #expect(chunks.count == 3)
        #expect(chunks[0].content == "1.1 First clause")
        #expect(chunks[2].content == "1.3 Third clause")
    }
}

// MARK: - Test doubles

/// Splits on `N.N` clause numbering — the shape a contracts corpus needs and sentences cannot see.
private struct ClauseSplitter: RTSRAGSplitter {
    func split(_ text: String) -> [Range<String.Index>] {
        let pattern = try? NSRegularExpression(pattern: #"\d+\.\d+"#)
        guard let pattern else {
            return []
        }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let starts = pattern.matches(in: text, range: full).compactMap {
            Range($0.range, in: text)?.lowerBound
        }
        guard !starts.isEmpty else {
            return []
        }
        return starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
            var trimmed = end
            while trimmed > starts[index], text[text.index(before: trimmed)].isWhitespace {
                trimmed = text.index(before: trimmed)
            }
            return starts[index]..<trimmed
        }
    }
}
