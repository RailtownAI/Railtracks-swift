//
//  RTSRAGSpotlightTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-28.
//

import Combine
import CoreSpotlight
import Foundation
import Synchronization
import Testing
@testable import RailtracksSwiftRAG

/// The Spotlight path: the chunk identifier, the feeder, and the ingest runtime.
///
/// Driven through an in-memory ``RTSRAGSpotlightIndexing`` so the suite runs without Spotlight —
/// real indexing needs an app, and is exercised once, against a named index, by the last test.
@Suite("RailtracksSwiftRAG Spotlight")
struct RTSRAGSpotlightTests {

    /// One chunk per document, so each ingest's counts are easy to read.
    private let identity = RTSRAGIdentityChunker()

    // MARK: - Positional identity

    @Test("a chunk's positional identifier is its document and index, and survives re-chunking")
    func positionalIdentifierIsStable() {
        let documentID = RTSRAGDocumentID(UUID())
        let first = RTSRAGChunk(content: "a", documentID: documentID, index: 2)
        let second = RTSRAGChunk(content: "a", documentID: documentID, index: 2)

        // The chunk ids differ — each is a fresh UUID — which is exactly why an outside index
        // cannot use them.
        #expect(first.id != second.id)
        #expect(first.positionalIdentifier == second.positionalIdentifier)
        #expect(first.positionalIdentifier == "\(documentID)#2")
    }

    // MARK: - Item mapping

    @Test("an item carries its chunk's position, text and staleness metadata")
    func itemMapping() throws {
        let documentID = RTSRAGDocumentID(UUID())
        let chunks = Self.chunks(
            documentID: documentID,
            contents: ["one", "two"],
            source: "/nowhere/notes.txt"
        )

        let items = RTSRAGSpotlightItem.items(for: chunks, of: documentID, namespace: "test.ns")

        #expect(items.map(\.uniqueIdentifier) == ["\(documentID)#0", "\(documentID)#1"])
        #expect(Set(items.map(\.domainIdentifier)) == ["test.ns.\(documentID)"])
        #expect(items.map(\.chunkCount) == [2, 2])
        #expect(items[1].textContent == "two")
        #expect(items[1].containerTitle == "notes.txt")
        #expect(items[1].contentHash == "hash")
        // The source does not exist, so it must not be presented as a location.
        #expect(items[1].contentURL == nil)

        let searchable = items[1].searchableItem()
        let attributes = searchable.attributeSet
        #expect(searchable.uniqueIdentifier == "\(documentID)#1")
        // Never left unset: the system's own expiry would empty the index without notice.
        #expect(searchable.expirationDate == .distantFuture)
        #expect(searchable.domainIdentifier == "test.ns.\(documentID)")
        #expect(attributes.textContent == "two")
        // `textContent` is never returned by a query, so the passage must also travel in an
        // attribute that is.
        #expect(attributes.contentDescription == "two")
        #expect(attributes.containerIdentifier == documentID.description)
        #expect(attributes.containerOrder == 1)
        let recordedCount = attributes.value(forCustomKey: RTSRAGSpotlightAttribute.chunkCount.key)
        let recordedSource = attributes.value(forCustomKey: RTSRAGSpotlightAttribute.sourcePath.key)
        #expect((recordedCount as? NSNumber)?.intValue == 2)
        #expect(recordedSource as? String == "/nowhere/notes.txt")
    }

    @Test("an existing source file becomes the item's content URL")
    func contentURLForAnExistingFile() throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        let path = try corpus.write("guide.txt", "hello")
        let documentID = RTSRAGDocumentID(UUID())

        let items = RTSRAGSpotlightItem.items(
            for: Self.chunks(documentID: documentID, contents: ["hello"], source: path.path),
            of: documentID,
            namespace: "test.ns"
        )

        #expect(items.first?.contentURL?.standardizedFileURL == path.standardizedFileURL)
    }

    @Test("a PDF page's source points its content URL at the PDF")
    func contentURLForAPDFPage() throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        let pdf = try corpus.write("manual.pdf", "stand-in bytes")
        // A file whose real name contains `#` must resolve to itself, not to a truncated path.
        let hashed = try corpus.write("notes#1.txt", "hello")
        let documentID = RTSRAGDocumentID(UUID())

        let pageSource = "\(pdf.path)#page-3"
        let page = RTSRAGSpotlightItem.items(
            for: Self.chunks(documentID: documentID, contents: ["p3"], source: pageSource),
            of: documentID,
            namespace: "test.ns"
        )
        let literal = RTSRAGSpotlightItem.items(
            for: Self.chunks(documentID: documentID, contents: ["n"], source: hashed.path),
            of: documentID,
            namespace: "test.ns"
        )

        #expect(page.first?.contentURL?.standardizedFileURL == pdf.standardizedFileURL)
        #expect(literal.first?.contentURL?.standardizedFileURL == hashed.standardizedFileURL)
    }

    @Test("a staleness query escapes quotes, backslashes and wildcards")
    func stalenessQueryEscaping() {
        let query = RTSRAGSpotlightFeeder.stalenessQuery(
            namespace: "ns",
            source: #"/a "quoted" \ path*"#,
            contentHash: "abc"
        )

        #expect(query.contains(#"rtsragSourcePath == "/a \"quoted\" \\ path\*""#))
        #expect(query.contains(#"rtsragNamespace == "ns""#))
        #expect(query.contains(" && "))
    }

    @Test("the search filter matches the namespace the staleness query uses")
    func searchFilterMatchesNamespace() {
        let feeder = RTSRAGSpotlightFeeder(indexing: FakeSpotlightIndex(), namespace: "app.rag")
        let staleness = RTSRAGSpotlightFeeder.stalenessQuery(
            namespace: "app.rag",
            source: "/s",
            contentHash: "h"
        )

        #expect(feeder.searchFilter == #"rtsragNamespace == "app.rag""#)
        #expect(staleness.hasPrefix(feeder.searchFilter))
    }

    // MARK: - Feeder

    @Test("replacing deletes the domain before indexing, so a shrunk document keeps no stragglers")
    func replaceDeletesFirst() async throws {
        let index = FakeSpotlightIndex()
        let feeder = RTSRAGSpotlightFeeder(indexing: index, namespace: "test.ns")
        let documentID = RTSRAGDocumentID(UUID())

        try await feeder.replaceDocument(
            id: documentID,
            with: Self.chunks(documentID: documentID, contents: ["a", "b", "c", "d", "e"])
        )
        try await feeder.replaceDocument(
            id: documentID,
            with: Self.chunks(documentID: documentID, contents: ["x", "y", "z"])
        )

        // Positional ids overwrite in place; without the delete, #3 and #4 would outlive the
        // version they belonged to and keep being retrieved.
        #expect(await index.identifiers == (0..<3).map { "\(documentID)#\($0)" })
        #expect(await index.contents == ["x", "y", "z"])
        let calls = await index.calls
        #expect(calls.suffix(2) == [.delete(["test.ns.\(documentID)"]), .index(3)])
    }

    @Test("a feeder's expiration date is stamped on every item it donates")
    func feederStampsExpiration() async throws {
        let index = FakeSpotlightIndex()
        let expiry = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
        let feeder = RTSRAGSpotlightFeeder(indexing: index, expirationDate: expiry)
        let documentID = RTSRAGDocumentID(UUID())

        try await feeder.replaceDocument(
            id: documentID,
            with: Self.chunks(documentID: documentID, contents: ["a", "b"])
        )

        #expect(await index.expirationDates == [expiry, expiry])
    }

    @Test("deleting everything removes this namespace and nothing else")
    func deleteAllIsScoped() async throws {
        let index = FakeSpotlightIndex()
        let ours = RTSRAGSpotlightFeeder(indexing: index, namespace: "rag.ours")
        let theirs = RTSRAGSpotlightFeeder(indexing: index, namespace: "rag.theirs")
        let first = RTSRAGDocumentID(UUID())
        let second = RTSRAGDocumentID(UUID())
        let mine = Self.chunks(documentID: first, contents: ["mine"])
        let other = Self.chunks(documentID: second, contents: ["other"])
        try await ours.replaceDocument(id: first, with: mine)
        try await theirs.replaceDocument(id: second, with: other)

        try await ours.deleteAll()

        #expect(await index.contents == ["other"])
    }

    @Test("stored and complete needs a match for every recorded chunk")
    func stalenessNeedsEveryChunk() async throws {
        let index = FakeSpotlightIndex()
        let feeder = RTSRAGSpotlightFeeder(indexing: index, namespace: "test.ns")
        let documentID = RTSRAGDocumentID(UUID())
        try await feeder.replaceDocument(
            id: documentID,
            with: Self.chunks(documentID: documentID, contents: ["a", "b", "c"], source: "/s")
        )

        #expect(try await feeder.isStoredAndComplete(source: "/s", contentHash: "hash"))
        #expect(try await !feeder.isStoredAndComplete(source: "/s", contentHash: "other"))

        // An interrupted donation: one of the three items never landed.
        await index.drop("\(documentID)#2")

        #expect(try await !feeder.isStoredAndComplete(source: "/s", contentHash: "hash"))
    }

    // MARK: - Runtime

    @Test("an unchanged document is skipped; an edited one is replaced")
    func runtimeSkipsAndReplaces() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let index = FakeSpotlightIndex()
        let runtime = Self.runtime(over: index)

        let first = try await runtime.ingest(loader: corpus.loader, chunker: identity)
        let unchanged = try await runtime.ingest(loader: corpus.loader, chunker: identity)
        try corpus.write("a.txt", "Refunds take sixty days.")
        let edited = try await runtime.ingest(loader: corpus.loader, chunker: identity)

        #expect(first.documentsCommitted == 1)
        #expect(first.chunksStored == 1)
        #expect(unchanged.documentsSkipped == 1)
        #expect(unchanged.documentsCommitted == 0)
        #expect(edited.documentsCommitted == 1)
        #expect(await index.contents == ["Refunds take sixty days."])
    }

    @Test("a document that chunks to nothing leaves its donated version alone")
    func runtimeLeavesEmptyDocumentsAlone() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let index = FakeSpotlightIndex()
        let runtime = Self.runtime(over: index)
        _ = try await runtime.ingest(loader: corpus.loader, chunker: identity)

        try corpus.write("a.txt", "Changed, but the chunker now drops everything.")
        let stats = try await runtime.ingest(loader: corpus.loader, chunker: NothingChunker())

        #expect(stats.documentsEmpty == 1)
        #expect(await index.contents == ["Refunds take thirty days."])
    }

    @Test("a failed donation withholds the document and does not end the run")
    func runtimeWithholdsOnDonationFailure() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "First document.")
        try corpus.write("b.txt", "Second document.")
        let index = FakeSpotlightIndex(failIndexingContaining: "First")
        let runtime = Self.runtime(over: index)

        let stats = try await runtime.ingest(loader: corpus.loader, chunker: identity)

        #expect(stats.documentsWithheld == 1)
        #expect(stats.documentsCommitted == 1)
        #expect(stats.documentsAccountedFor == stats.documentsLoaded)
        #expect(await index.contents == ["Second document."])
    }

    @Test("a failing staleness query re-donates rather than ending the run")
    func runtimeSurvivesAFailingQuery() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let index = FakeSpotlightIndex(failQueries: true)
        let runtime = Self.runtime(over: index)

        _ = try await runtime.ingest(loader: corpus.loader, chunker: identity)
        let again = try await runtime.ingest(loader: corpus.loader, chunker: identity)

        // The check exists only to save work, so its failure costs a re-donation, and the domain
        // delete keeps that free of duplicates.
        #expect(again.documentsCommitted == 1)
        #expect(await index.contents == ["Refunds take thirty days."])
    }

    @Test("a second concurrent ingest is refused and the first completes")
    func runtimeRefusesConcurrentIngest() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let runtime = Self.runtime(over: FakeSpotlightIndex())
        let chunker = SlowChunker(delay: .milliseconds(300))

        let running = Task {
            try await runtime.ingest(loader: corpus.loader, chunker: chunker)
        }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: RTSRAGError.self) {
            try await runtime.ingest(loader: corpus.loader, chunker: chunker)
        }

        #expect(try await running.value.documentsCommitted == 1)
    }

    @Test("the event stream accounts for the run")
    func runtimeEvents() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let runtime = Self.runtime(over: FakeSpotlightIndex())
        let events = Mutex<[RTSRAGIngestEvent]>([])
        let subscription = runtime.eventPublisher.sink { event in
            events.withLock { $0.append(event) }
        }
        defer {
            subscription.cancel()
        }

        _ = try await runtime.ingest(loader: corpus.loader, chunker: identity)

        let names = events.withLock { $0.map(Self.name) }
        #expect(names == ["loaded", "chunked", "committed"])
    }

    // MARK: - Real Spotlight

    /// The one test against a real `CSSearchableIndex` — a *named* one, so it never touches the
    /// default index an app shares with other code.
    ///
    /// It also proves the one thing the fake cannot: that Spotlight answers the staleness query —
    /// a predicate over custom attributes, with the chunk count read back through
    /// `fetchAttributes`.
    /// Indexing is asynchronous (a call returns once the request is journaled), so both directions
    /// are polled rather than asserted immediately.
    ///
    /// Skipped when Spotlight indexing is unavailable. It runs under command-line `swift test`
    /// despite there being no app bundle.
    @Test("a named index answers the staleness check, and forgets on delete")
    func namedIndexRoundTrip() async throws {
        guard CSSearchableIndex.isIndexingAvailable() else {
            return
        }
        let namespace = "railtracks.rag.test.\(UUID().uuidString.prefix(8))"
        let source = "/rts-rag-test/\(namespace)"
        let feeder = RTSRAGSpotlightFeeder(
            index: CSSearchableIndex(name: "railtracks-rag-tests"),
            namespace: namespace
        )
        let documentID = RTSRAGDocumentID(UUID())
        defer {
            Task {
                try? await feeder.deleteAll()
            }
        }

        try await feeder.replaceDocument(
            id: documentID,
            with: Self.chunks(documentID: documentID, contents: ["a", "b"], source: source)
        )
        let stored = try await Self.poll {
            try await feeder.isStoredAndComplete(source: source, contentHash: "hash")
        }
        try await feeder.deleteAll()
        let forgotten = try await Self.poll {
            try await !feeder.isStoredAndComplete(source: source, contentHash: "hash")
        }

        #expect(stored)
        #expect(forgotten)
    }

    // MARK: - Helpers

    private static func runtime(over index: FakeSpotlightIndex) -> RTSRAGSpotlightIngestRuntime {
        RTSRAGSpotlightIngestRuntime(feeder: RTSRAGSpotlightFeeder(indexing: index))
    }

    /// Retries `condition` for up to five seconds, for Spotlight's asynchronous indexing.
    private static func poll(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<25 {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private static func chunks(
        documentID: RTSRAGDocumentID,
        contents: [String],
        source: String = "/source"
    ) -> [RTSRAGChunk] {
        contents.enumerated().map { index, content in
            RTSRAGChunk(
                content: content,
                documentID: documentID,
                index: index,
                metadata: [
                    RTSRAGChunk.MetadataKey.sourcePath: .string(source),
                    RTSRAGChunk.MetadataKey.contentHash: .string("hash"),
                ]
            )
        }
    }

    private static func name(_ event: RTSRAGIngestEvent) -> String {
        switch event {
        case .documentLoaded:
            return "loaded"
        case .documentChunked:
            return "chunked"
        case .documentCommitted:
            return "committed"
        case .documentSkipped:
            return "skipped"
        case .documentEmpty:
            return "empty"
        case .documentWithheld:
            return "withheld"
        case .batchEmbedded, .batchFailed:
            return "embedding"
        case .loadFailed:
            return "loadFailed"
        }
    }

    private struct Corpus {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-rag-spotlight-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var loader: RTSRAGTextLoader {
            RTSRAGTextLoader(path: directory)
        }

        @discardableResult
        func write(_ name: String, _ contents: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

// MARK: - Test doubles

/// An in-memory Spotlight index that behaves like the real one where the feeder depends on it.
///
/// Domain deletion is recursive, as Spotlight documents it. A query is answered by matching each
/// stored item's own staleness query against the one asked — so the test exercises the exact string
/// the feeder builds, without the double having to parse Spotlight's query language.
private actor FakeSpotlightIndex: RTSRAGSpotlightIndexing {

    enum Call: Equatable {
        case index(Int)
        case delete([String])
    }

    private var items: [String: RTSRAGSpotlightItem] = [:]
    private(set) var calls: [Call] = []
    private let failIndexingContaining: String?
    private let failQueries: Bool

    init(
        failIndexingContaining: String? = nil,
        failQueries: Bool = false
    ) {
        self.failIndexingContaining = failIndexingContaining
        self.failQueries = failQueries
    }

    var identifiers: [String] {
        items.keys.sorted()
    }

    var contents: [String] {
        sortedItems.map(\.textContent)
    }

    var expirationDates: [Date] {
        sortedItems.map(\.expirationDate)
    }

    private var sortedItems: [RTSRAGSpotlightItem] {
        items.values.sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
    }

    func drop(_ identifier: String) {
        items.removeValue(forKey: identifier)
    }

    func index(_ newItems: [RTSRAGSpotlightItem]) async throws {
        calls.append(.index(newItems.count))
        if let marker = failIndexingContaining {
            if newItems.contains(where: { $0.textContent.contains(marker) }) {
                throw RTSRAGError.storeFailed(reason: "stubbed indexing failure")
            }
        }
        for item in newItems {
            items[item.uniqueIdentifier] = item
        }
    }

    func deleteItems(inDomains domainIdentifiers: [String]) async throws {
        calls.append(.delete(domainIdentifiers))
        items = items.filter { _, item in
            !domainIdentifiers.contains { domain in
                item.domainIdentifier == domain || item.domainIdentifier.hasPrefix(domain + ".")
            }
        }
    }

    func records(matching queryString: String) async throws -> [RTSRAGSpotlightRecord] {
        if failQueries {
            throw RTSRAGError.storeFailed(reason: "stubbed query failure")
        }
        return items.values
            .filter { item in
                guard let source = item.sourcePath, let hash = item.contentHash else {
                    return false
                }
                let own = RTSRAGSpotlightFeeder.stalenessQuery(
                    namespace: item.namespace,
                    source: source,
                    contentHash: hash
                )
                return own == queryString
            }
            .map { item in
                RTSRAGSpotlightRecord(
                    uniqueIdentifier: item.uniqueIdentifier,
                    chunkCount: item.chunkCount
                )
            }
    }
}

/// Chunks every document to nothing, like a sanitizer that dropped all of it.
private struct NothingChunker: RTSRAGChunker {
    func chunk(_ document: RTSRAGDocument) async throws -> [RTSRAGChunk] {
        []
    }
}

/// One chunk per document, held open long enough for a second ingest to arrive mid-run.
private struct SlowChunker: RTSRAGChunker {
    let delay: Duration

    func chunk(_ document: RTSRAGDocument) async throws -> [RTSRAGChunk] {
        try await Task.sleep(for: delay)
        return try await RTSRAGIdentityChunker().chunk(document)
    }
}
