//
//  RTSRAGModelTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// Phase 1 of the RAG port: the module's models and identity rules. No pipeline behaviour exists
/// yet, so these also serve as the proof that the target builds and links on its own.
///
/// Deliberately *not* nested in a root suite: this target needs none of the main target's
/// `.serialized` / `RedirectsOutput` machinery, because nothing here can reach
/// `RailtracksSwift.outputDirectory` — the module does not depend on that module at all, and
/// `RTSRAGFileStore` takes its directory from the caller. Every test that touches disk names its
/// own path under `FileManager.default.temporaryDirectory` and removes it.
///
/// Keep that true. Swift Testing traits do not cross target boundaries, so a component that ever
/// *derives* an output path instead of being handed one would write into the developer's
/// `~/Documents` with nothing here to stop it.
@Suite("RailtracksSwiftRAG models")
struct RTSRAGModelTests {

    // MARK: - Document identity

    @Test("a source yields the same document id every time")
    func derivedIDIsStable() {
        let first = RTSRAGDocument(content: "one", source: "file:///docs/policy.md")
        let second = RTSRAGDocument(
            content: "two — different content",
            source: "file:///docs/policy.md"
        )

        // Stability across processes is what makes an update replace rather than duplicate: the
        // pipeline clears the prior version by id, which only works if the id is reproducible.
        // Note it is derived from `source` alone — changed content must not change the id.
        #expect(first.id == second.id)
    }

    @Test("different sources yield different ids")
    func distinctSourcesDiffer() {
        let a = RTSRAGDocument(content: "same", source: "file:///a.md")
        let b = RTSRAGDocument(content: "same", source: "file:///b.md")

        // Identical content at two sources stays two documents. Deduplication is by source
        // identity, not by content, so provenance survives — at the cost of two near-identical
        // hits at query time.
        #expect(a.id != b.id)
    }

    @Test("a sourceless document gets a random id and so has no update semantics")
    func sourcelessDocumentsAreUnique() {
        let first = RTSRAGDocument(content: "identical")
        let second = RTSRAGDocument(content: "identical")

        #expect(first.id != second.id)
    }

    @Test("derived ids match RFC 4122 version 5 in the URL namespace")
    func derivedIDIsUUID5() {
        let id = RTSRAGDocument.derivedID(for: "file:///docs/policy.md")
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }

        // Version 5 in the high nibble of byte 6, RFC 4122 variant in the top bits of byte 8.
        // Pinned because the construction matches Python's `uuid5(NAMESPACE_URL, source)`, so a
        // store written by either engine agrees on document ids.
        #expect(bytes[6] & 0xF0 == 0x50)
        #expect(bytes[8] & 0xC0 == 0x80)
    }

    // MARK: - Document type

    @Test("an app can name a format the library has never heard of")
    func documentTypeIsOpen() {
        // The point of the open type. There is no format registry — a caller picks a loader by
        // constructing it — so an app writing a `.docx` loader must be able to say so rather than
        // mislabelling its output as `.text`.
        let custom = RTSRAGDocumentType(rawValue: "docx")

        #expect(custom != .text)
        #expect(custom.rawValue == "docx")
    }

    @Test("a document type codes as a bare string")
    func documentTypeCodesAsBareString() throws {
        let encoded = try JSONEncoder().encode([RTSRAGDocumentType.jsonLines])

        // Pinned because this reaches persisted stores: a `{"rawValue": "jsonl"}` object would be
        // a silent format break against both the closed enum this replaced and Python's values.
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"jsonl\"]")
    }

    @Test("an unrecognised document type decodes rather than throwing")
    func unknownDocumentTypeDecodes() throws {
        let decoded = try JSONDecoder().decode(
            [RTSRAGDocumentType].self,
            from: Data("[\"docx\"]".utf8)
        )

        // A closed enum throws here, which would make a store written by a build — or a Python
        // engine — that knows one extra format unreadable rather than merely less informative.
        #expect(decoded == [RTSRAGDocumentType(rawValue: "docx")])
    }

    @Test("derived ids match values computed by Python's uuid5")
    func derivedIDMatchesPython() {
        // Vectors from `uuid5(NAMESPACE_URL, source)` in the Python engine's interpreter. The
        // structural check above passes for any SHA-1-shaped construction — a wrong namespace, or
        // hashing source before namespace, would satisfy it and still disagree with Python. Only
        // a known value catches that, and the two engines sharing a store depends on it.
        #expect(
            RTSRAGDocument.derivedID(for: "file:///docs/policy.md").uuidString.lowercased()
                == "14e95f57-eeff-5dd0-bc6a-daab0d3413e2"
        )
        #expect(
            RTSRAGDocument.derivedID(for: "/Users/x/a.pdf#page-2").uuidString.lowercased()
                == "112b8095-b64a-5d8f-8976-d83f09f482e2"
        )
    }

    // MARK: - Content hashing

    @Test("content hashing answers whether a source changed")
    func contentHashDistinguishesContent() {
        let original = RTSRAGContentHash.of("the refund policy is 30 days")
        let unchanged = RTSRAGContentHash.of("the refund policy is 30 days")
        let edited = RTSRAGContentHash.of("the refund policy is 60 days")

        #expect(original == unchanged)
        #expect(original != edited)
        #expect(original.count == 64)   // SHA-256, hex encoded
    }

    // MARK: - Chunks

    @Test("a chunk carries its position rather than relying on write order")
    func chunkOrderingIsData() {
        let documentID = RTSRAGDocumentID(UUID())
        let chunks = (0..<3).map { index in
            RTSRAGChunk(content: "piece \(index)", documentID: documentID, index: index)
        }

        // Entries are written under their own ids, so writes may be reordered or parallelised;
        // `index` is the only ordering signal that survives storage.
        #expect(chunks.map { $0.index } == [0, 1, 2])
        #expect(Set(chunks.map { $0.id }).count == 3)
    }

    // MARK: - Store entries

    @Test("a store entry keeps both the vector and the text")
    func storeEntryCarriesContent() {
        let chunk = RTSRAGChunk(
            content: "refunds are processed within 30 days",
            documentID: RTSRAGDocumentID(UUID()),
            index: 4
        )
        let embedded = RTSRAGEmbeddedChunk(
            chunk: chunk,
            vector: [0.1, 0.2, 0.3],
            embeddingModel: "text-embedding-3-small"
        )
        let entry = RTSRAGStoreEntry(embedded: embedded)

        // The vector does the matching; the stored text is what a hit hands back for reading or
        // for a prompt. Losing either would make retrieval useless.
        #expect(entry.vector == [0.1, 0.2, 0.3])
        #expect(entry.content == chunk.content)
        #expect(entry.chunkIndex == 4)
        #expect(entry.embeddingModel == "text-embedding-3-small")
    }

    // MARK: - Metadata

    @Test("metadata round-trips through JSON with its types intact")
    func metadataRoundTrips() throws {
        let metadata: RTSRAGMetadata = [
            "jurisdiction": .string("TX"),
            "revision": .integer(3),
            "confidence": .double(0.82),
            "archived": .boolean(false),
        ]

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RTSRAGMetadata.self, from: encoded)

        // Type fidelity matters because stores filter on flat equality: an integer that came back
        // as a double would silently stop matching.
        #expect(decoded == metadata)
    }

    // MARK: - Limits

    @Test("the character limit sits under the provider's token ceiling for any corpus")
    func chunkLimitIsSafe() {
        // Even at the pessimistic end — a few tokens per character for emoji-heavy text — the
        // character limit cannot produce a chunk over the provider cap. That headroom is what
        // makes a token counter unnecessary.
        let worstCaseTokensPerCharacter = 4
        let worstCase = RTSRAGLimits.defaultMaxChunkCharacters * worstCaseTokensPerCharacter

        #expect(worstCase < RTSRAGLimits.maxEmbeddingInputTokens)
    }
}
