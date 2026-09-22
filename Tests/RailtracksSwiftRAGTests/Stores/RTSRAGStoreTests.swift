//
//  RTSRAGStoreTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-18.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// Phase 5: the stores.
///
/// Both conformers run the **same** assertions through the protocol, so behaviour cannot drift
/// between them — the file store is meant to add durability and nothing else, and a shared suite is
/// what keeps that true rather than hoped for.
@Suite("RailtracksSwiftRAG stores")
struct RTSRAGStoreTests {

    /// Which conformer a case runs against. Parameterising on this is what makes the suite shared.
    enum Kind: CaseIterable {
        case inMemory
        case file
    }

    // MARK: - Shared behaviour

    @Test("entries written for a document come back ranked", arguments: Kind.allCases)
    func roundTrip(kind: Kind) async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try scratch.makeStore(kind)
        let documentID = RTSRAGDocumentID(UUID())

        try await store.replaceDocument(
            id: documentID,
            with: [
                Self.entry(documentID: documentID, index: 0, content: "refunds", vector: [1, 0, 0]),
                Self.entry(documentID: documentID, index: 1, content: "shipping", vector: [0, 1, 0]),
            ]
        )
        let hits = try await store.search(Self.query([0.9, 0.1, 0]))

        #expect(hits.count == 2)
        #expect(hits[0].entry.content == "refunds")
        #expect(hits[0].rank == 0)
        #expect(hits[0].score > hits[1].score)
    }

    @Test("replacing a document is whole-document, not additive", arguments: Kind.allCases)
    func replaceIsWholeDocument(kind: Kind) async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try scratch.makeStore(kind)
        let documentID = RTSRAGDocumentID(UUID())

        try await store.replaceDocument(
            id: documentID,
            with: (0..<3).map { Self.entry(documentID: documentID, index: $0, content: "old \($0)", vector: [1, 0, 0]) }
        )
        try await store.replaceDocument(
            id: documentID,
            with: [Self.entry(documentID: documentID, index: 0, content: "new", vector: [1, 0, 0])]
        )
        let hits = try await store.search(Self.query([1, 0, 0], topK: 10))

        // The reason replacement is one operation rather than a delete followed by writes: the
        // three old chunks must be gone, not orphaned alongside the new one, where they would keep
        // answering queries with content the document no longer has.
        #expect(hits.count == 1)
        #expect(hits[0].entry.content == "new")
    }

    @Test("deleting removes every chunk of the document", arguments: Kind.allCases)
    func deleteRemovesTheDocument(kind: Kind) async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try scratch.makeStore(kind)
        let kept = RTSRAGDocumentID(UUID())
        let removed = RTSRAGDocumentID(UUID())

        try await store.replaceDocument(id: kept, with: [Self.entry(documentID: kept, index: 0, content: "kept", vector: [1, 0, 0])])
        try await store.replaceDocument(id: removed, with: [Self.entry(documentID: removed, index: 0, content: "gone", vector: [1, 0, 0])])
        try await store.deleteDocument(id: removed)
        let hits = try await store.search(Self.query([1, 0, 0], topK: 10))

        #expect(hits.map { $0.entry.content } == ["kept"])
    }

    @Test("a vector of the wrong width is refused, not scored", arguments: Kind.allCases)
    func dimensionMismatchThrows(kind: Kind) async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try scratch.makeStore(kind)
        let documentID = RTSRAGDocumentID(UUID())
        try await store.replaceDocument(
            id: documentID,
            with: [Self.entry(documentID: documentID, index: 0, content: "a", vector: [1, 0, 0])]
        )

        // Conduit's `cosineSimilarity` returns 0 on a dimension mismatch rather than throwing,
        // which presents as "nothing matches anything" with no indication why. A store must not
        // reproduce that — at write or at query.
        await #expect(throws: RTSRAGError.self) {
            try await store.replaceDocument(
                id: RTSRAGDocumentID(UUID()),
                with: [Self.entry(documentID: RTSRAGDocumentID(UUID()), index: 0, content: "b", vector: [1, 0])]
            )
        }
        await #expect(throws: RTSRAGError.self) {
            _ = try await store.search(Self.query([1, 0]))
        }
    }

    @Test("a second embedding model is refused", arguments: Kind.allCases)
    func modelMismatchThrows(kind: Kind) async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try scratch.makeStore(kind)
        let first = RTSRAGDocumentID(UUID())
        try await store.replaceDocument(
            id: first,
            with: [Self.entry(documentID: first, index: 0, content: "a", vector: [1, 0, 0])]
        )

        // Scores across two vector spaces are meaningless but well-formed, so a mixed index returns
        // confident nonsense rather than an error. This is what the *composite* modelIdentifier
        // from phase 4 buys — a friendly name would let a store built under different pooling
        // through this check.
        let second = RTSRAGDocumentID(UUID())
        await #expect(throws: RTSRAGError.self) {
            try await store.replaceDocument(
                id: second,
                with: [
                    Self.entry(
                        documentID: second,
                        index: 0,
                        content: "b",
                        vector: [1, 0, 0],
                        model: "openai/text-embedding-3-small"
                    )
                ]
            )
        }
    }

    @Test("find and count agree, and match on staleness metadata", arguments: Kind.allCases)
    func findAndCountSupportTheStalenessCheck(kind: Kind) async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try scratch.makeStore(kind)
        let documentID = RTSRAGDocumentID(UUID())
        let metadata: RTSRAGMetadata = [
            RTSRAGChunk.MetadataKey.sourcePath: .string("file:///a.txt"),
            RTSRAGChunk.MetadataKey.contentHash: .string("abc123"),
        ]
        try await store.replaceDocument(
            id: documentID,
            with: (0..<3).map {
                Self.entry(documentID: documentID, index: $0, content: "c\($0)", vector: [1, 0, 0], metadata: metadata)
            }
        )

        // Phase 6's commit rule turns on exactly this pair: `count` tells it whether the store
        // already holds as many chunks as the last write expected, without transferring payloads.
        let found = try await store.find(matching: metadata, limit: 10)
        let counted = try await store.count(matching: metadata)
        let missing = try await store.count(matching: [RTSRAGChunk.MetadataKey.contentHash: .string("changed")])

        #expect(found.count == 3)
        #expect(counted == 3)
        #expect(missing == 0)
    }

    @Test("retrieval finds the passage that answers the query", arguments: Kind.allCases)
    func rankingIsMeaningful(kind: Kind) async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try scratch.makeStore(kind)
        let embedder = try RTSRAGAppleEmbedding()
        try await embedder.prepare()
        let documentID = RTSRAGDocumentID(UUID())
        let passages = [
            "Refunds are processed within thirty days of receipt.",
            "Our offices are closed on public holidays.",
            "The warehouse is located near the airport.",
        ]
        let vectors = try await embedder.embed(passages).vectors
        try await store.replaceDocument(
            id: documentID,
            with: zip(passages, vectors).enumerated().map { index, pair in
                Self.entry(
                    documentID: documentID,
                    index: index,
                    content: pair.0,
                    vector: pair.1,
                    model: embedder.modelIdentifier
                )
            }
        )

        let question = "how long do I have to get my money back?"
        let queryVector = try await embedder.embed([question]).vectors[0]
        let hits = try await store.search(
            RTSRAGStoreQuery(text: question, embedding: queryVector, topK: 3)
        )

        // The end-to-end claim the whole port rests on, and the first point at which it can be
        // checked: a question phrased in words the passage never uses still retrieves it. Every
        // other test here would pass against a store of zeros.
        #expect(hits.first?.entry.content == passages[0])
    }

    // MARK: - File store only

    @Test("a reopened store still answers queries")
    func fileStoreIsDurable() async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let documentID = RTSRAGDocumentID(UUID())
        do {
            let store = try RTSRAGFileStore(directory: scratch.directory)
            try await store.replaceDocument(
                id: documentID,
                with: [Self.entry(documentID: documentID, index: 0, content: "survives", vector: [1, 0, 0])]
            )
        }

        let reopened = try RTSRAGFileStore(directory: scratch.directory)
        let hits = try await reopened.search(Self.query([1, 0, 0]))

        #expect(hits.map { $0.entry.content } == ["survives"])
    }

    @Test("a torn final line costs one document, not the store")
    func fileStoreToleratesATornLine() async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let good = RTSRAGDocumentID(UUID())
        let torn = RTSRAGDocumentID(UUID())
        do {
            let store = try RTSRAGFileStore(directory: scratch.directory)
            try await store.replaceDocument(id: good, with: [Self.entry(documentID: good, index: 0, content: "intact", vector: [1, 0, 0])])
            try await store.replaceDocument(id: torn, with: [Self.entry(documentID: torn, index: 0, content: "lost", vector: [1, 0, 0])])
        }
        // Simulate a crash mid-append by truncating the last line.
        let url = scratch.directory.appendingPathComponent("entries.jsonl")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = String(text.dropLast(40))
        try text.write(to: url, atomically: true, encoding: .utf8)

        let reopened = try RTSRAGFileStore(directory: scratch.directory)
        let hits = try await reopened.search(Self.query([1, 0, 0], topK: 10))

        // The point of one line per document: a half-written line loses that document and nothing
        // else, and the staleness check re-ingests it on the next run.
        #expect(hits.map { $0.entry.content } == ["intact"])
    }

    @Test("repeated replacement compacts instead of growing without bound")
    func fileStoreCompacts() async throws {
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let store = try RTSRAGFileStore(directory: scratch.directory)
        let documentID = RTSRAGDocumentID(UUID())
        let url = scratch.directory.appendingPathComponent("entries.jsonl")

        for revision in 0..<30 {
            try await store.replaceDocument(
                id: documentID,
                with: [Self.entry(documentID: documentID, index: 0, content: "revision \(revision)", vector: [1, 0, 0])]
            )
        }

        // Writes append rather than editing in place — a text file cannot edit a line without
        // rewriting the remainder — so without compaction an edit-heavy corpus grows for ever.
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let hits = try await store.search(Self.query([1, 0, 0], topK: 10))
        #expect(lines.count < 30)
        #expect(hits.map { $0.entry.content } == ["revision 29"])
    }

    @Test("a refused append costs one document, not the log")
    func fileStoreSurvivesARefusedAppend() async throws {
        guard getuid() != 0 else {
            // Root ignores the read-only bit, so the failure cannot be provoked and a pass would
            // mean nothing.
            return
        }
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let url = scratch.directory.appendingPathComponent("entries.jsonl")
        let store = try RTSRAGFileStore(directory: scratch.directory)
        let first = RTSRAGDocumentID(UUID())
        let second = RTSRAGDocumentID(UUID())
        try await store.replaceDocument(id: first, with: [Self.entry(documentID: first, index: 0, content: "one", vector: [1, 0, 0])])
        try await store.replaceDocument(id: second, with: [Self.entry(documentID: second, index: 0, content: "two", vector: [1, 0, 0])])

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let blocked = RTSRAGDocumentID(UUID())
        await #expect(throws: (any Error).self) {
            try await store.replaceDocument(
                id: blocked,
                with: [Self.entry(documentID: blocked, index: 0, content: "three", vector: [1, 0, 0])]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        // An earlier version opened the handle with `try?` and, on failure, wrote the single line
        // with `.atomic` — meaning to say "the file does not exist yet". Any open failure therefore
        // replaced the entire log with one document, which is what this pins.
        let reopened = try RTSRAGFileStore(directory: scratch.directory)
        let hits = try await reopened.search(Self.query([1, 0, 0], topK: 10))

        #expect(Set(hits.map { $0.entry.content }) == ["one", "two"])
    }

    @Test("a refused append leaves no phantom document in memory")
    func fileStoreRollsBackARefusedAppend() async throws {
        guard getuid() != 0 else {
            return
        }
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        let url = scratch.directory.appendingPathComponent("entries.jsonl")
        let store = try RTSRAGFileStore(directory: scratch.directory)
        let kept = RTSRAGDocumentID(UUID())
        let blocked = RTSRAGDocumentID(UUID())
        let keptMetadata: RTSRAGMetadata = [RTSRAGChunk.MetadataKey.sourcePath: .string("file:///kept.txt")]
        let blockedMetadata: RTSRAGMetadata = [RTSRAGChunk.MetadataKey.sourcePath: .string("file:///blocked.txt")]
        try await store.replaceDocument(
            id: kept,
            with: [Self.entry(documentID: kept, index: 0, content: "kept", vector: [1, 0, 0], metadata: keptMetadata)]
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        await #expect(throws: (any Error).self) {
            try await store.replaceDocument(
                id: blocked,
                with: [Self.entry(documentID: blocked, index: 0, content: "blocked", vector: [1, 0, 0], metadata: blockedMetadata)]
            )
        }
        await #expect(throws: (any Error).self) {
            try await store.deleteDocument(id: kept)
        }
        let phantom = try await store.count(matching: blockedMetadata)
        let survivor = try await store.count(matching: keptMetadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        // Reads answer from the index, not the file — so a write left in memory after the log
        // refused it is exactly what makes `RTSRAGRetrievalRuntime`'s staleness check skip a
        // document it just reported as failed, for the rest of the process. The tombstone has the
        // same requirement in the other direction: a delete the log refused must not take the
        // document out of memory.
        #expect(phantom == 0)
        #expect(survivor == 1)
    }

    @Test("a refused first write does not pin the store to a model it never held")
    func fileStoreRollsBackIdentity() async throws {
        guard getuid() != 0 else {
            return
        }
        let scratch = try Scratch()
        defer {
            scratch.clean()
        }
        // The log has to *exist* to be made unwritable — `append` creates it when absent, so an
        // absent file would simply succeed.
        let url = scratch.directory.appendingPathComponent("entries.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let store = try RTSRAGFileStore(directory: scratch.directory)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let refused = RTSRAGDocumentID(UUID())
        await #expect(throws: (any Error).self) {
            try await store.replaceDocument(
                id: refused,
                with: [Self.entry(documentID: refused, index: 0, content: "a", vector: [1, 0, 0], model: "model/ALPHA")]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        // The store holds nothing, so it must behave like the empty store it is. An earlier
        // rollback put the document back but not the identity fields the same write had latched,
        // leaving an empty store that refused this with "store was built with model/ALPHA" — about
        // a document that was never written, in a store with no entries at all.
        let accepted = RTSRAGDocumentID(UUID())
        try await store.replaceDocument(
            id: accepted,
            with: [Self.entry(documentID: accepted, index: 0, content: "b", vector: [1, 0, 0, 0, 0], model: "model/BETA")]
        )
        let hits = try await store.search(Self.query([1, 0, 0, 0, 0]))

        #expect(hits.map { $0.entry.content } == ["b"])
    }

    // MARK: - Helpers

    /// A throwaway directory, so the file store never touches a developer's own files.
    private struct Scratch {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-rag-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func makeStore(_ kind: Kind) throws -> any RTSRAGVectorStore {
            switch kind {
            case .inMemory:
                return RTSRAGInMemoryStore()
            case .file:
                return try RTSRAGFileStore(directory: directory)
            }
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func entry(
        documentID: RTSRAGDocumentID,
        index: Int,
        content: String,
        vector: [Float],
        model: String = "test/model",
        metadata: RTSRAGMetadata = [:]
    ) -> RTSRAGStoreEntry {
        RTSRAGStoreEntry(
            embedded: RTSRAGEmbeddedChunk(
                chunk: RTSRAGChunk(
                    content: content,
                    documentID: documentID,
                    index: index,
                    metadata: metadata
                ),
                vector: vector,
                embeddingModel: model
            )
        )
    }

    private static func query(_ embedding: [Float], topK: Int = 5) -> RTSRAGStoreQuery {
        RTSRAGStoreQuery(text: "q", embedding: embedding, topK: topK)
    }
}
