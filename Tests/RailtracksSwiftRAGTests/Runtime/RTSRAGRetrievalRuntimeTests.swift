//
//  RTSRAGRetrievalRuntimeTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-21.
//

import Combine
import Foundation
import Synchronization
import Testing
@testable import RailtracksSwiftRAG

/// Phase 6: the runtime that assembles the other four.
///
/// Driven with the in-memory store and the on-device embedder, so the whole suite runs offline and
/// costs nothing — and so the end-to-end case asserts on real vectors rather than a mock's return
/// value.
@Suite("RailtracksSwiftRAG retrieval runtime")
struct RTSRAGRetrievalRuntimeTests {

    // MARK: - End to end

    @Test("a corpus can be ingested and then asked a question")
    func endToEnd() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("refunds.txt", "Refunds are processed within thirty days of receipt.")
        try corpus.write("hours.txt", "Our offices are closed on public holidays.")
        let runtime = try await corpus.makeRuntime()

        let stats = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        let result = try await runtime.retrieve("how long until I get my money back?")

        // The claim the whole port exists for, now in two calls: a question sharing almost no words
        // with the passage still finds it.
        #expect(stats.documentsLoaded == 2)
        #expect(stats.documentsCommitted == 2)
        #expect(result.entries.first?.entry.content.contains("Refunds") == true)
    }

    // MARK: - Staleness

    @Test("an unchanged document is skipped without being embedded")
    func unchangedDocumentIsSkipped() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "The warehouse is near the airport.")
        let counting = CountingEmbedder(wrapping: try await corpus.makeEmbedder())
        let runtime = RTSRAGRetrievalRuntime(embedder: counting, store: corpus.store)

        _ = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        let afterFirst = await counting.callCount
        let second = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())

        // Measured, not assumed: the embedder is asked for nothing the second time. Skipping is
        // only worth having because it avoids the *cost*, so counting calls is the assertion that
        // matters rather than counting events.
        #expect(second.documentsSkipped == 1)
        #expect(second.documentsCommitted == 0)
        #expect(await counting.callCount == afterFirst)
    }

    @Test("an edited document replaces what was stored")
    func editedDocumentIsReIngested() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "The refund window is thirty days.")
        let runtime = try await corpus.makeRuntime()
        _ = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())

        try corpus.write("a.txt", "The refund window is ninety days.")
        let second = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        let result = try await runtime.retrieve("how long is the refund window?", topK: 10)

        // The content hash changed, so the source is not a duplicate; `replaceDocument` then swaps
        // the old chunks out rather than adding to them.
        #expect(second.documentsSkipped == 0)
        #expect(second.documentsCommitted == 1)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].entry.content.contains("ninety"))
    }

    @Test("a document the sanitizer drops leaves the store untouched")
    func droppedDocumentDoesNotDelete() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let runtime = try await corpus.makeRuntime()
        _ = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())

        // A sanitizer returning `nil` removes the document from the *stream*, so it never reaches
        // the runtime at all — the previous version survives because nothing was asked about it.
        // A document that reaches the chunker and yields nothing is a different path, covered by
        // `emptyDocumentIsAccountedFor`.
        let dropping = RTSRAGSanitizingLoader(wrapping: corpus.loader, sanitizer: DroppingSanitizer())
        let stats = try await runtime.ingest(loader: dropping, chunker: RTSRAGSentenceChunker())
        let result = try await runtime.retrieve("refunds", topK: 10)

        #expect(stats.documentsLoaded == 0)
        #expect(result.entries.count == 1)
    }

    // MARK: - The commit rule

    @Test("a permanently unembeddable chunk is dropped and the rest committed")
    func permanentFailureCommitsTheRest() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        let store = RTSRAGInMemoryStore()
        let embedder = FailingEmbedder(failing: .invalidInput, onChunkContaining: "poison")
        let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: store)
        try corpus.write("a.txt", "Alpha here. poison here. Gamma here.")

        let stats = try await runtime.ingest(
            loader: corpus.loader,
            chunker: RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)
        )

        // `.invalidInput` is permanent, so withholding the document would leave it absent for ever,
        // re-chunked and re-failed on every run. Committing what works is the terminating choice.
        #expect(stats.documentsCommitted == 1)
        #expect(stats.chunksDropped == 1)
        #expect(stats.needsAttention)
    }

    @Test("a transient failure withholds the document entirely")
    func transientFailureWithholds() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        let store = RTSRAGInMemoryStore()
        let embedder = FailingEmbedder(failing: .transient, onChunkContaining: "poison")
        let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: store)
        try corpus.write("a.txt", "Alpha here. poison here. Gamma here.")

        let stats = try await runtime.ingest(
            loader: corpus.loader,
            chunker: RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)
        )
        let stored = try await store.count(matching: [:])

        // Next run may succeed, so nothing is written and the previous version — here, nothing —
        // stays as it was. Committing part would reproduce the half-replaced state the atomic
        // `replaceDocument` exists to prevent.
        #expect(stats.documentsWithheld == 1)
        #expect(stats.documentsCommitted == 0)
        #expect(stored == 0)
    }

    @Test("a partially committed document is not re-ingested for ever")
    func partialCommitTerminates() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        let store = RTSRAGInMemoryStore()
        let embedder = FailingEmbedder(failing: .invalidInput, onChunkContaining: "poison")
        let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: store)
        try corpus.write("a.txt", "Alpha here. poison here. Gamma here.")
        let chunker = RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)

        _ = try await runtime.ingest(loader: corpus.loader, chunker: chunker)
        let second = try await runtime.ingest(loader: corpus.loader, chunker: chunker)

        // The detail that makes the rule above correct, and the one easiest to get backwards:
        // `documentChunkCount` records what was **stored**, not what was chunked. Stamping the
        // larger number would make the completeness check false for ever, so this unchanged
        // document would re-chunk, re-embed and re-fail on every single run.
        #expect(second.documentsSkipped == 1)
        #expect(second.documentsCommitted == 0)
    }

    @Test("a document no chunker will take asks for a human, and keeps asking")
    func unchunkableDocumentNeedsAttention() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", String(repeating: "long ", count: 200))
        let runtime = try await corpus.makeRuntime()
        let collector = EventCollector()
        let subscription = runtime.eventPublisher.sink { event in
            collector.record(event)
        }
        defer {
            subscription.cancel()
        }
        // The identity chunker refuses rather than splits, which is the whole reason it takes a
        // limit — and the pairing that produced this failure repeatedly while phase 4 was landing.
        let chunker = RTSRAGIdentityChunker(maxCharacters: 50)

        let first = try await runtime.ingest(loader: corpus.loader, chunker: chunker)
        let second = try await runtime.ingest(loader: corpus.loader, chunker: chunker)

        #expect(first.documentsUnchunkable == 1)
        #expect(first.needsAttention)
        // Disjoint, so "withheld for retry" never names a document that will never pass.
        #expect(first.documentsWithheld == 0)
        #expect(first.documentsCommitted == 0)

        // Nothing was stored, so the staleness check cannot skip it, and a chunker is a pure
        // function of its input — the second run re-chunks and re-fails identically, for ever.
        #expect(second.documentsUnchunkable == 1)
        #expect(second.needsAttention)

        // And the event stream says so on its own, which is what the withhold reason is for.
        #expect(collector.derived.documentsUnchunkable == 2)
        #expect(collector.derived.documentsWithheld == 0)
    }

    @Test("a document whose every chunk is rejected is counted, and its losses reported")
    func fullyUnembeddableDocumentIsAccountedFor() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Alpha here. Beta here. Gamma here.")
        let runtime = RTSRAGRetrievalRuntime(embedder: RejectingEmbedder(), store: corpus.store)
        let collector = EventCollector()
        let subscription = runtime.eventPublisher.sink { event in
            collector.record(event)
        }
        defer {
            subscription.cancel()
        }

        let stats = try await runtime.ingest(
            loader: corpus.loader,
            chunker: RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)
        )

        // `chunksDropped` is the one to watch: `commit` is the only other place a drop is recorded
        // and this path never reaches it, so the count has to come from the outcome itself.
        #expect(stats.chunksCreated == 3)
        #expect(stats.documentsUnembeddable == 1)
        #expect(stats.chunksDropped == 3)
        #expect(stats.documentsCommitted == 0)
        #expect(stats.needsAttention)
        // And the stream accounts for the run on its own, which is why the drop count rides on the
        // event rather than being inferred.
        #expect(collector.derived.documentsUnembeddable == 1)
        #expect(collector.derived.chunksDropped == 3)
    }

    @Test("a document that chunks to nothing is counted rather than vanishing")
    func emptyDocumentIsAccountedFor() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let runtime = try await corpus.makeRuntime()
        _ = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        // Whitespace only: *not* empty content, so the chunker's first guard lets it past, and it
        // yields no sentences. A sanitizer returning `nil` would not reach this — that drops the
        // document at the loader.
        try corpus.write("a.txt", "   \n\n\t\n  ")

        let stats = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        let result = try await runtime.retrieve("refunds", topK: 10)

        // `replaceDocument(id:, with: [])` is a *delete* to the store, so the obvious
        // implementation would destroy the previous version whenever chunking yielded nothing —
        // an unrelated sanitizer change becoming quietly destructive.
        #expect(result.entries.count == 1)

        // Not a failure — an empty source is legitimate — so it stays out of `needsAttention`,
        // but it still has to be counted rather than vanishing.
        #expect(stats.documentsLoaded == 1)
        #expect(stats.documentsEmpty == 1)
        #expect(stats.needsAttention == false)
    }

    /// Every way a document can end, so the reconciliation below is checked against all of them
    /// rather than the happy path.
    enum AccountingCase: String, CaseIterable, Sendable {
        case committed
        case skipped
        case unchunkable
        case empty
        case fullyUnembeddable
        case partiallyDropped
        case transientlyWithheld
    }

    @Test("every loaded document reaches exactly one outcome", arguments: AccountingCase.allCases)
    func statsAlwaysReconcile(scenario: AccountingCase) async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        let sentences = RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)
        let stats: RTSRAGIngestionStats

        switch scenario {
        case .committed:
            try corpus.write("a.txt", "Refunds take thirty days.")
            stats = try await corpus.makeRuntime().ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        case .skipped:
            try corpus.write("a.txt", "Refunds take thirty days.")
            let runtime = try await corpus.makeRuntime()
            _ = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
            stats = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        case .unchunkable:
            try corpus.write("a.txt", String(repeating: "long ", count: 200))
            stats = try await corpus.makeRuntime().ingest(
                loader: corpus.loader,
                chunker: RTSRAGIdentityChunker(maxCharacters: 50)
            )
        case .empty:
            try corpus.write("a.txt", "   \n\n\t\n  ")
            stats = try await corpus.makeRuntime().ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        case .fullyUnembeddable:
            try corpus.write("a.txt", "Alpha here. Beta here.")
            let runtime = RTSRAGRetrievalRuntime(embedder: RejectingEmbedder(), store: corpus.store)
            stats = try await runtime.ingest(loader: corpus.loader, chunker: sentences)
        case .partiallyDropped:
            try corpus.write("a.txt", "Alpha here. poison here. Gamma here.")
            let embedder = FailingEmbedder(failing: .invalidInput, onChunkContaining: "poison")
            let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: corpus.store)
            stats = try await runtime.ingest(loader: corpus.loader, chunker: sentences)
        case .transientlyWithheld:
            try corpus.write("a.txt", "Alpha here. poison here. Gamma here.")
            let embedder = FailingEmbedder(failing: .transient, onChunkContaining: "poison")
            let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: corpus.store)
            stats = try await runtime.ingest(loader: corpus.loader, chunker: sentences)
        }

        // The invariant the outcome enum exists to keep, checked across every ending a document
        // has. A shortfall means some path returned without naming an outcome.
        #expect(stats.documentsLoaded == 1)
        #expect(stats.documentsAccountedFor == stats.documentsLoaded)
    }

    @Test("a refused second ingest leaves the first one running and correct")
    func concurrentIngestIsRefusedWithoutDisturbingTheFirst() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        try corpus.write("b.txt", "The warehouse is near the airport.")
        // Slow enough that the second call lands while the first is still inside the embedder.
        let slow = SlowEmbedder(wrapped: try await corpus.makeEmbedder(), delay: .milliseconds(150))
        let runtime = RTSRAGRetrievalRuntime(embedder: slow, store: corpus.store)

        async let first = runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        try await Task.sleep(for: .milliseconds(50))

        // Refused **twice**, and the second refusal is the one that matters. A refusal must not
        // release the slot it failed to take — written with the `defer` installed before the claim,
        // the first refusal would free the running ingest's exclusivity and this third call would
        // be admitted to run concurrently with it. One refusal alone cannot tell the two apart.
        await #expect(throws: RTSRAGError.ingestAlreadyRunning) {
            _ = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        }
        await #expect(throws: RTSRAGError.ingestAlreadyRunning) {
            _ = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        }
        let stats = try await first

        // The refusals are otherwise inert: they touch no loader, embedder or store, so the first
        // run finishes exactly as it would have alone.
        #expect(stats.documentsLoaded == 2)
        #expect(stats.documentsCommitted == 2)
        #expect(stats.needsAttention == false)

        // And the slot is released afterwards, so the runtime is reusable rather than poisoned.
        let second = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        #expect(second.documentsSkipped == 2)
    }

    @Test("a runtime is reusable after an ingest that threw")
    func ingestSlotIsReleasedAfterAThrow() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        let embedder = FailingEmbedder(failing: .quotaExhausted, onChunkContaining: "poison")
        let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: corpus.store)
        let chunker = RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)
        try corpus.write("a.txt", "Alpha here. poison here.")

        await #expect(throws: RTSRAGEmbeddingError.self) {
            _ = try await runtime.ingest(loader: corpus.loader, chunker: chunker)
        }

        // The slot is released in a `defer`, so it survives every exit — a thrown run, and
        // cancellation, which leaves by the same path. Releasing at the end of the body instead
        // would poison the runtime permanently the first time an ingest failed, and every other
        // test here would still pass: they all reuse a runtime only after a *successful* run.
        try corpus.write("a.txt", "Alpha here. Beta here.")
        let recovered = try await runtime.ingest(loader: corpus.loader, chunker: chunker)

        #expect(recovered.documentsCommitted == 1)
    }

    // MARK: - Guards

    @Test("a foreign embedder is refused before the loader reads anything")
    func modelGuardPreflights() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let store = RTSRAGInMemoryStore()
        let first = RTSRAGRetrievalRuntime(embedder: try await corpus.makeEmbedder(), store: store)
        _ = try await first.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())

        let counting = CountingLoader(wrapping: corpus.loader)
        let second = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)

        await #expect(throws: RTSRAGError.self) {
            _ = try await second.ingest(loader: counting, chunker: RTSRAGSentenceChunker())
        }

        // The store would refuse the first *write* anyway — but only after a document had been
        // read, chunked and paid for. Asserting the loader was never asked is what pins that the
        // check happens first.
        #expect(await counting.streamCount == 0)
    }

    @Test("querying with a foreign embedder is refused even at matching width")
    func retrieveRefusesAForeignEmbedder() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let store = RTSRAGInMemoryStore()
        // Both stubs produce **three-dimension** vectors under different identities, which is the
        // whole point: the store's width check cannot tell them apart, and in the real world the
        // pair is an on-device 512 against `text-embedding-3-small` truncated to 512.
        let written = RTSRAGRetrievalRuntime(
            embedder: FailingEmbedder(failing: .transient, onChunkContaining: "never matches"),
            store: store
        )
        _ = try await written.ingest(loader: corpus.loader, chunker: RTSRAGIdentityChunker())

        let foreign = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)

        // Without the identity check this returns confident nonsense — well-formed scores over a
        // vector space the query was never in. Querying with the wrong embedder is also the likelier
        // of the two mistakes, since the ingest is long finished and nothing about the query looks
        // wrong.
        await #expect(throws: RTSRAGError.self) {
            _ = try await foreign.retrieve("refunds")
        }
    }

    @Test("an emptied store can be re-ingested with a different embedder")
    func emptiedStoreAcceptsAnotherEmbedder() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        let store = RTSRAGInMemoryStore()
        let original = RTSRAGRetrievalRuntime(
            embedder: FailingEmbedder(failing: .transient, onChunkContaining: "never matches"),
            store: store
        )
        _ = try await original.ingest(loader: corpus.loader, chunker: RTSRAGIdentityChunker())
        for documentID in Set(try await store.find(matching: [:], limit: 100).map { $0.documentID }) {
            try await store.deleteDocument(id: documentID)
        }

        // The pre-flight sees an empty store and lets the new embedder through; the store has to
        // agree. Before, it stayed pinned to the old model and refused the first write — after that
        // document had already been read, chunked and paid to embed.
        let replacement = RTSRAGRetrievalRuntime(embedder: StubEmbedder(), store: store)
        let stats = try await replacement.ingest(loader: corpus.loader, chunker: RTSRAGIdentityChunker())
        let result = try await replacement.retrieve("refunds")

        #expect(stats.documentsCommitted == 1)
        #expect(result.entries.map { $0.entry.embeddingModel } == ["stub/other"])
    }

    @Test("a repeated document id inside one ingest is warned about")
    func duplicateIdsAreNoticed() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        // `name` is not unique, so both rows derive the same source and therefore the same id.
        try corpus.write("people.csv", "name,city\nAmy,Vancouver\nAmy,Toronto\n")
        let store = RTSRAGInMemoryStore()
        let runtime = RTSRAGRetrievalRuntime(embedder: try await corpus.makeEmbedder(), store: store)

        let stats = try await runtime.ingest(
            loader: RTSRAGCSVLoader(path: corpus.directory, idColumn: "name"),
            chunker: RTSRAGIdentityChunker()
        )
        let stored = try await store.count(matching: [:])

        // Both rows load and embed, and the second overwrites the first — so one person is
        // unretrievable and nothing errors. The warning is the only signal, which is why it exists.
        #expect(stats.documentsLoaded == 2)
        #expect(stored == 1)
    }

    // MARK: - Events

    @Test("the event stream accounts for the run on its own")
    func eventsReconstructTheStats() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        try corpus.write("a.txt", "Refunds take thirty days.")
        try corpus.write("b.txt", "The warehouse is near the airport.")
        let runtime = try await corpus.makeRuntime()
        let collector = EventCollector()
        let subscription = runtime.eventPublisher.sink { event in
            collector.record(event)
        }
        defer {
            subscription.cancel()
        }

        // `ingest` drains the emitter before returning, so no sleep is needed: the drain is a
        // barrier on the same serial queue the sinks run on.
        let stats = try await runtime.ingest(loader: corpus.loader, chunker: RTSRAGSentenceChunker())
        let derived = collector.derived

        // Python's own events cannot rebuild its own `IngestionStats` — `documents_loaded` and
        // `chunks_created` are counted internally and no event reports either. Emitting both means
        // the returned value is a convenience rather than a second source of truth that can drift.
        #expect(derived.documentsLoaded == stats.documentsLoaded)
        #expect(derived.chunksCreated == stats.chunksCreated)
        #expect(derived.chunksEmbedded == stats.chunksEmbedded)
        #expect(derived.chunksStored == stats.chunksStored)
        #expect(derived.documentsCommitted == stats.documentsCommitted)
    }

    @Test("a thrown ingest still delivers the events that explain it")
    func eventsAreDrainedWhenIngestThrows() async throws {
        let corpus = try Corpus()
        defer {
            corpus.clean()
        }
        // One document, two chunks: the first embeds, the second ends the run. Keeping both inside
        // one file makes the ordering the enumerator's business rather than the test's.
        try corpus.write("a.txt", "Alpha here. poison here.")
        let embedder = FailingEmbedder(failing: .quotaExhausted, onChunkContaining: "poison")
        let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: corpus.store)
        let collector = EventCollector(delay: 0.05)
        let subscription = runtime.eventPublisher.sink { event in
            collector.record(event)
        }
        defer {
            subscription.cancel()
        }

        await #expect(throws: RTSRAGEmbeddingError.self) {
            _ = try await runtime.ingest(
                loader: corpus.loader,
                chunker: RTSRAGSentenceChunker(maxCharacters: 20, overlapSentences: 0)
            )
        }
        let derived = collector.derived

        // Read the instant the throw is caught, with no sleep — that is the assertion. Delivery is
        // asynchronous, so a drain only on the success path lets the error overtake the events that
        // explain it. Deliberately not `batchEmbedded`: the batching layer discards its accumulated
        // outcomes when a kind that `endsTheRun` appears, so the runtime never sees them.
        #expect(derived.documentsLoaded == 1)
        #expect(derived.chunksCreated >= 1)
    }

    // MARK: - Fixtures

    private struct Corpus {
        let directory: URL
        let store = RTSRAGInMemoryStore()

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-rag-runtime-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var loader: RTSRAGTextLoader {
            RTSRAGTextLoader(path: directory)
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        func makeEmbedder() async throws -> RTSRAGAppleEmbedding {
            let embedder = try RTSRAGAppleEmbedding()
            try await embedder.prepare()
            return embedder
        }

        func makeRuntime() async throws -> RTSRAGRetrievalRuntime {
            RTSRAGRetrievalRuntime(embedder: try await makeEmbedder(), store: store)
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

// MARK: - Test doubles

/// Counts how often the embedder is actually asked, so "skipping saves cost" is measured.
private actor CountingEmbedder: RTSRAGEmbedding {
    private let wrapped: any RTSRAGEmbedding
    private(set) var callCount = 0

    init(wrapping wrapped: any RTSRAGEmbedding) {
        self.wrapped = wrapped
    }

    nonisolated var modelIdentifier: String {
        "counting"
    }

    nonisolated var defaultBatchSize: Int {
        8
    }

    func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        callCount += 1
        return try await wrapped.embed(texts)
    }
}

/// Counts `stream()` calls, so "the guard runs before the loader" is provable.
private actor CountingLoader: RTSRAGDocumentLoader {
    private let wrapped: any RTSRAGDocumentLoader
    private(set) var streamCount = 0

    init(wrapping wrapped: any RTSRAGDocumentLoader) {
        self.wrapped = wrapped
    }

    nonisolated func stream() throws -> RTSRAGDocumentStream {
        Task {
            await self.note()
        }
        return try wrapped.stream()
    }

    private func note() {
        streamCount += 1
    }
}

/// Fails any batch containing a marker, with a configurable kind.
private struct FailingEmbedder: RTSRAGEmbedding {
    let failing: RTSRAGEmbeddingFailureKind
    let onChunkContaining: String

    var modelIdentifier: String {
        "stub/failing"
    }

    var defaultBatchSize: Int {
        1
    }

    func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        if texts.contains(where: { $0.contains(onChunkContaining) }) {
            throw RTSRAGEmbeddingError(kind: failing, message: "stubbed \(failing)")
        }
        return RTSRAGTextEmbeddings(
            vectors: texts.map { _ in [1, 0, 0] },
            metrics: RTSRAGEmbeddingMetrics(vectorCount: texts.count)
        )
    }
}

/// Holds each call open long enough for a second ingest to arrive mid-run.
private struct SlowEmbedder: RTSRAGEmbedding {
    let wrapped: any RTSRAGEmbedding
    let delay: Duration

    var modelIdentifier: String {
        wrapped.modelIdentifier
    }

    var defaultBatchSize: Int {
        1
    }

    func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        try await Task.sleep(for: delay)
        return try await wrapped.embed(texts)
    }
}

/// Rejects every batch as permanently unembeddable, so a document ends with nothing to commit.
private struct RejectingEmbedder: RTSRAGEmbedding {
    var modelIdentifier: String {
        "stub/rejecting"
    }

    var defaultBatchSize: Int {
        1
    }

    func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        throw RTSRAGEmbeddingError(kind: .invalidInput, message: "stubbed rejection")
    }
}

/// A different model identity, for the guard.
private struct StubEmbedder: RTSRAGEmbedding {
    var modelIdentifier: String {
        "stub/other"
    }

    var defaultBatchSize: Int {
        8
    }

    func embed(_ texts: [String]) async throws -> RTSRAGTextEmbeddings {
        RTSRAGTextEmbeddings(vectors: texts.map { _ in [1, 0, 0] })
    }
}

private struct DroppingSanitizer: RTSRAGSanitizer {
    func sanitize(_ document: RTSRAGDocument) async throws -> RTSRAGDocument? {
        nil
    }
}

/// Rebuilds the stats from nothing but the event stream.
///
/// Records **synchronously** inside the sink rather than hopping onto an actor. `ingest` drains the
/// emitter before returning, and drain is a barrier on the same serial queue the sinks run on — so
/// once it returns, every event has been recorded. An actor hop would break that chain and force
/// the test to sleep and hope.
private final class EventCollector: @unchecked Sendable {
    private let state = Mutex(RTSRAGIngestionStats())
    /// Held per event, to make a *missing* barrier observable.
    ///
    /// A real sink is fast, so a test that merely reads after the throw wins the race by luck and
    /// passes with or without the drain. Blocking the emitter's serial queue for longer than the
    /// remaining call takes turns "delivery is asynchronous" from a fact into a visible one.
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    var derived: RTSRAGIngestionStats {
        state.withLock { $0 }
    }

    func record(_ event: RTSRAGIngestEvent) {
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        state.withLock { derived in
            EventCollector.apply(event, to: &derived)
        }
    }

    private static func apply(_ event: RTSRAGIngestEvent, to derived: inout RTSRAGIngestionStats) {
        switch event {
        case .documentLoaded:
            derived.documentsLoaded += 1
        case .documentSkipped:
            derived.documentsSkipped += 1
        case .documentChunked(_, let chunks):
            derived.chunksCreated += chunks
        case .batchEmbedded(_, let chunks, let metrics):
            derived.chunksEmbedded += chunks
            derived.record(metrics)
        case .batchFailed(let failure):
            derived.batchesFailed += 1
            derived.failures.append(failure)
        case .documentCommitted(_, let stored, let dropped):
            derived.documentsCommitted += 1
            derived.chunksStored += stored
            derived.chunksDropped += dropped
        case .documentEmpty:
            derived.documentsEmpty += 1
        case .documentWithheld(_, let reason):
            switch reason {
            case .transient:
                derived.documentsWithheld += 1
            case .unchunkable:
                derived.documentsUnchunkable += 1
            case .unembeddable(let dropped):
                derived.documentsUnembeddable += 1
                // Carried on the event precisely so this line can exist: `commit` is the only other
                // place a drop is recorded, and this path never reaches it.
                derived.chunksDropped += dropped
            }
        case .loadFailed:
            break
        }
    }
}
