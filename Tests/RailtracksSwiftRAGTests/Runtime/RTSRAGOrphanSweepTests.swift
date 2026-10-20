//
//  RTSRAGOrphanSweepTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-30.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// The orphan sweep: the root rule, the pure orphan rule, store listing, and the sweep end to end
/// through `RTSRAGRetrievalRuntime`. The Spotlight runtime's sweep is covered in its own suite.
@Suite("RailtracksSwiftRAG orphan sweep")
struct RTSRAGOrphanSweepTests {

    /// One chunk per document, so each run's counts are easy to read.
    private let identity = RTSRAGIdentityChunker()

    // MARK: - RTSRAGSourceRoot

    @Test("a root contains itself, its parts, and what is inside it — nothing merely similar")
    func rootContainment() {
        let root = RTSRAGSourceRoot(path: "/docs/a")

        #expect(root.contains(source: "/docs/a"))
        #expect(root.contains(source: "/docs/a#page-3"))
        #expect(root.contains(source: "/docs/a/b.txt"))
        // The separators are what stop a sibling with a longer name from being claimed.
        #expect(!root.contains(source: "/docs/ab"))
        #expect(!root.contains(source: "/docs/a.txt"))
        #expect(!root.contains(source: "/docs"))
    }

    @Test("a trailing slash on the root does not change what it contains")
    func rootTrailingSlash() {
        let root = RTSRAGSourceRoot(path: "/docs/a/")

        #expect(root.path == "/docs/a")
        #expect(root.contains(source: "/docs/a/b.txt"))
    }

    @Test("a root under /var also matches its /private spelling, and back")
    func rootPrivateSpelling() {
        // Folder enumeration reports `/private/var/…` for a root given as `/var/…`; without this
        // a sweep of any temporary or container folder would find nothing to compare against.
        let given = RTSRAGSourceRoot(path: "/var/folders/x/docs")
        let resolved = RTSRAGSourceRoot(path: "/private/var/folders/x/docs")

        #expect(given.contains(source: "/private/var/folders/x/docs/a.txt"))
        #expect(resolved.contains(source: "/var/folders/x/docs/a.txt"))
        #expect(!RTSRAGSourceRoot(path: "/Users/me").contains(source: "/private/Users/me/a.txt"))
    }

    // MARK: - The orphan rule

    @Test("orphans are unseen, unfiltered, and not under a failed source")
    func orphanRule() {
        let seen = RTSRAGDocumentID(UUID())
        let filtered = RTSRAGDocumentID(UUID())
        let failed = RTSRAGDocumentID(UUID())
        let orphan = RTSRAGDocumentID(UUID())
        let stored: [RTSRAGDocumentID: String] = [
            seen: "/r/seen.txt",
            filtered: "/r/filtered.txt",
            failed: "/r/broken.pdf#page-2",
            orphan: "/r/moved.txt",
        ]

        let orphans = RTSRAGOrphanSweep.orphans(
            stored: stored,
            seen: [seen],
            filtered: [filtered],
            failedSources: [URL(fileURLWithPath: "/r/broken.pdf")]
        )

        #expect(orphans == [RTSRAGOrphanSweep.Orphan(id: orphan, source: "/r/moved.txt")])
    }

    // MARK: - Store listing

    @Test(
        "a store lists documents under a root, in exactly the scope asked",
        arguments: StoreKind.allCases
    )
    func storeListing(kind: StoreKind) async throws {
        let workspace = try Workspace()
        defer {
            workspace.clean()
        }
        let store = try workspace.makeStore(kind)
        let tenant = RTSRAGStoreScope(labels: ["tenant": "a"])
        try await Self.put(source: "/r/one.txt", in: store)
        try await Self.put(source: "/r/sub/two.pdf#page-1", in: store)
        try await Self.put(source: "/elsewhere/three.txt", in: store)
        try await Self.put(source: "/r/tenant.txt", in: store, scope: tenant)

        let unscoped = try await store.documents(under: RTSRAGSourceRoot(path: "/r"), scope: nil)
        let scoped = try await store.documents(under: RTSRAGSourceRoot(path: "/r"), scope: tenant)

        // Unlike retrieval, `nil` is not "every scope": this listing is what a sweep deletes from.
        #expect(Set(unscoped.values) == ["/r/one.txt", "/r/sub/two.pdf#page-1"])
        #expect(Set(scoped.values) == ["/r/tenant.txt"])
    }

    // MARK: - Sweep through the runtime

    @Test("a file moved within the root is swept from its old path")
    func moveWithinRoot() async throws {
        let workspace = try Workspace()
        defer {
            workspace.clean()
        }
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        try workspace.write("a.txt", "Refunds take thirty days.")
        _ = try await runtime.ingest(loader: workspace.loader, chunker: identity)

        try workspace.move("a.txt", to: "b.txt")
        let stats = try await runtime.ingest(loader: workspace.loader, chunker: identity)

        let names = try await Self.fileNames(in: store, under: workspace.directory)
        #expect(names == ["b.txt"])
        #expect(stats.documentsSwept == 1)
    }

    @Test("opting out of the sweep leaves the old path in place")
    func optOut() async throws {
        let workspace = try Workspace()
        defer {
            workspace.clean()
        }
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        try workspace.write("a.txt", "Refunds take thirty days.")
        _ = try await runtime.ingest(loader: workspace.loader, chunker: identity)

        try workspace.move("a.txt", to: "b.txt")
        let stats = try await runtime.ingest(
            loader: workspace.loader,
            chunker: RTSRAGIdentityChunker(),
            sweepsOrphans: false
        )

        let names = try await Self.fileNames(in: store, under: workspace.directory)
        #expect(names == ["a.txt", "b.txt"])
        #expect(stats.documentsSwept == 0)
    }

    @Test("a file root sweeps the pages that are gone from a shrunk file")
    func shrunkFile() async throws {
        let file = URL(fileURLWithPath: "/virtual/report.pdf")
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        let threePages = PageLoader(file: file, pages: ["one", "two", "three"])
        _ = try await runtime.ingest(loader: threePages, chunker: RTSRAGIdentityChunker())

        let twoPages = PageLoader(file: file, pages: ["one", "two"])
        let stats = try await runtime.ingest(loader: twoPages, chunker: RTSRAGIdentityChunker())

        let sources = try await Self.sources(in: store, under: file)
        #expect(sources == ["\(file.path)#page-1", "\(file.path)#page-2"])
        #expect(stats.documentsSwept == 1)
    }

    @Test("documents outside the root and in another scope are never swept")
    func outsideRootAndScope() async throws {
        let workspace = try Workspace()
        defer {
            workspace.clean()
        }
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        let tenant = RTSRAGStoreScope(labels: ["tenant": "b"])
        try await Self.put(source: "/elsewhere/keep.txt", in: store)
        try await Self.put(source: workspace.path("tenant.txt"), in: store, scope: tenant)
        try workspace.write("a.txt", "Refunds take thirty days.")

        let stats = try await runtime.ingest(loader: workspace.loader, chunker: identity)

        let elsewhere = RTSRAGSourceRoot(path: "/elsewhere")
        let outside = try await store.documents(under: elsewhere, scope: nil)
        let within = RTSRAGSourceRoot(workspace.directory)
        let other = try await store.documents(under: within, scope: tenant)
        #expect(outside.count == 1)
        #expect(other.count == 1)
        #expect(stats.documentsSwept == 0)
    }

    @Test("a document a sanitizer drops keeps its stored version")
    func sanitizerDropIsKept() async throws {
        let file = URL(fileURLWithPath: "/virtual/notes.pdf")
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        _ = try await runtime.ingest(
            loader: PageLoader(file: file, pages: ["public", "secret"]),
            chunker: RTSRAGIdentityChunker()
        )

        // The sanitizer now drops page 2. It still exists at its source; deleting its stored
        // version on absence would make a sanitizer change quietly destructive.
        let sanitized = RTSRAGSanitizingLoader(
            wrapping: PageLoader(file: file, pages: ["public", "secret"]),
            sanitizer: DroppingSanitizer(marker: "secret")
        )
        let stats = try await runtime.ingest(loader: sanitized, chunker: RTSRAGIdentityChunker())

        let sources = try await Self.sources(in: store, under: file)
        #expect(sources.count == 2)
        #expect(stats.documentsSwept == 0)
    }

    @Test("a source that fails to load keeps everything stored for it")
    func failedSourceIsKept() async throws {
        let file = URL(fileURLWithPath: "/virtual/flaky.pdf")
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        _ = try await runtime.ingest(
            loader: PageLoader(file: file, pages: ["one", "two"]),
            chunker: RTSRAGIdentityChunker()
        )

        let stats = try await runtime.ingest(
            loader: PageLoader(file: file, pages: ["one", "two"], failing: true),
            chunker: RTSRAGIdentityChunker()
        )

        let sources = try await Self.sources(in: store, under: file)
        #expect(sources.count == 2)
        #expect(stats.documentsSwept == 0)
    }

    @Test("a loader with no root is never swept")
    func noRootNoSweep() async throws {
        let file = URL(fileURLWithPath: "/virtual/report.pdf")
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        _ = try await runtime.ingest(
            loader: PageLoader(file: file, pages: ["one", "two", "three"]),
            chunker: RTSRAGIdentityChunker()
        )

        let stats = try await runtime.ingest(
            loader: PageLoader(file: file, pages: ["one"], declaresRoot: false),
            chunker: RTSRAGIdentityChunker()
        )

        #expect(try await Self.sources(in: store, under: file).count == 3)
        #expect(stats.documentsSwept == 0)
    }

    // MARK: - removeSource(at:)

    @Test("removing a source removes every part of a file, and everything in a folder")
    func removeSource() async throws {
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        try await Self.put(source: "/r/report.pdf#page-1", in: store)
        try await Self.put(source: "/r/report.pdf#page-2", in: store)
        try await Self.put(source: "/r/sub/notes.txt", in: store)
        try await Self.put(source: "/r/keep.txt", in: store)

        let fromFile = try await runtime.removeSource(at: URL(fileURLWithPath: "/r/report.pdf"))
        let fromFolder = try await runtime.removeSource(at: URL(fileURLWithPath: "/r/sub"))

        #expect(fromFile == 2)
        #expect(fromFolder == 1)
        let remaining = try await store.documents(under: RTSRAGSourceRoot(path: "/r"), scope: nil)
        #expect(Array(remaining.values) == ["/r/keep.txt"])
    }

    // MARK: - Helpers

    enum StoreKind: CaseIterable {
        case inMemory
        case file
    }

    /// Stores one single-chunk document for `source`, as an ingest would.
    private static func put(
        source: String,
        in store: any RTSRAGVectorStore,
        scope: RTSRAGStoreScope? = nil
    ) async throws {
        let documentID = RTSRAGDocumentID(RTSRAGDocument.derivedID(for: source))
        let chunk = RTSRAGChunk(
            content: "content of \(source)",
            documentID: documentID,
            metadata: [RTSRAGChunk.MetadataKey.sourcePath: .string(source)]
        )
        let embedded = RTSRAGEmbeddedChunk(
            chunk: chunk,
            vector: [1, 0, 0],
            embeddingModel: "stub/orphan"
        )
        let entry = RTSRAGStoreEntry(embedded: embedded, scope: scope)
        try await store.replaceDocument(id: documentID, with: [entry])
    }

    private static func sources(
        in store: any RTSRAGVectorStore,
        under root: URL
    ) async throws -> [String] {
        try await store.documents(under: RTSRAGSourceRoot(root), scope: nil).values.sorted()
    }

    /// File names only: a folder loader stores the *resolved* spelling (`/private/var/…`) of a
    /// temporary directory the test knows as `/var/…`, so whole paths would not compare.
    private static func fileNames(
        in store: any RTSRAGVectorStore,
        under root: URL
    ) async throws -> [String] {
        try await sources(in: store, under: root).map { ($0 as NSString).lastPathComponent }
    }

    /// A throwaway directory of text files, and a text loader over it.
    private struct Workspace {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-rag-orphan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var loader: RTSRAGTextLoader {
            RTSRAGTextLoader(path: directory)
        }

        func path(_ name: String) -> String {
            directory.appendingPathComponent(name).path
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        func move(_ name: String, to newName: String) throws {
            try FileManager.default.moveItem(
                at: directory.appendingPathComponent(name),
                to: directory.appendingPathComponent(newName)
            )
        }

        func makeStore(_ kind: StoreKind) throws -> any RTSRAGVectorStore {
            switch kind {
            case .inMemory:
                return RTSRAGInMemoryStore()
            case .file:
                return try RTSRAGFileStore(directory: directory.appendingPathComponent("store"))
            }
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

// MARK: - Test doubles

/// One document per page of a single file, like `RTSRAGPDFLoader` — without needing a real PDF.
///
/// The file root is what makes a shrunk file sweepable; `declaresRoot: false` models a custom
/// loader that states none, and `failing` makes the file's read throw.
private struct PageLoader: RTSRAGDocumentLoader {
    let file: URL
    let pages: [String]
    var failing = false
    var declaresRoot = true

    func stream() throws -> RTSRAGDocumentStream {
        let file = self.file
        let pages = self.pages
        let failing = self.failing
        return RTSRAGDocumentStream(sources: [file], root: declaresRoot ? file : nil) { _ in
            if failing {
                throw RTSRAGError.loadFailed(source: file.path, reason: "stubbed failure")
            }
            return pages.enumerated().map { index, text in
                RTSRAGDocument(content: text, source: "\(file.path)#page-\(index + 1)")
            }
        }
    }
}

/// Drops any document containing a marker, like a PII or policy sanitizer.
private struct DroppingSanitizer: RTSRAGSanitizer {
    let marker: String

    func sanitize(_ document: RTSRAGDocument) async throws -> RTSRAGDocument? {
        document.content.contains(marker) ? nil : document
    }
}

/// A fixed three-dimension embedder, so the suite runs offline and fast.
private struct StubEmbedder: RTSRAGEmbedding {
    var modelIdentifier: String {
        "stub/orphan"
    }

    var defaultBatchSize: Int {
        8
    }

    func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        RTSRAGTextEmbeddings(vectors: texts.map { _ in [1, 0, 0] })
    }
}
