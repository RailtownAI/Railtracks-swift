//
//  RTSRAGRetrievalRuntime.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-21.
//

import Combine
import Foundation
import Synchronization

/// Runs the pipeline: loader → chunker → embedder → store, one document at a time.
///
/// ```swift
/// let runtime = RTSRAGRetrievalRuntime(embedder: embedder, store: store)
/// let stats = try await runtime.ingest(
///     loader: RTSRAGTextLoader(path: directory),
///     chunker: RTSRAGSentenceChunker(maxCharacters: 768)
/// )
/// let hits = try await runtime.retrieve("what is the refund window?")
/// ```
///
/// ## One loader per call, and the chunker rides along
///
/// Python's `RetrievalRuntime.__init__` takes `(chunker, embedder, store)`, binding one chunker for
/// the runtime's whole life — so a corpus needing heading-aware splitting for prose and
/// one-chunk-per-record for a CSV needs two runtimes sharing a store, which is legal and which
/// nothing in its API suggests. Moving the chunker to ``ingest(loader:chunker:scope:)`` makes a
/// per-format pairing the ordinary case, and leaves `init` with exactly what ``retrieve(_:topK:filters:scope:)``
/// needs.
///
/// A mixed directory is therefore two calls, not a list. That is deliberate: two calls are two
/// independent ingests where a repeat is a *legitimate update*, while two entries in one list would
/// silently double-embed and let the last one win.
///
/// ## One ingest per runtime; concurrency comes from a second runtime
///
/// ``ingest(loader:chunker:scope:)`` refuses a second concurrent call on the same instance. Two
/// ingests at once on one runtime would interleave their events on one publisher with nothing to
/// tell them apart — the events carry a document id, not a run id — and nobody gains anything from
/// it, because a second runtime is a plain object over the same embedder and store.
///
/// So concurrency is expressed by building two runtimes, which also puts the question of what they
/// share where the caller can see it. The store is an actor and `replaceDocument` is one operation,
/// so writes cannot interleave within a document.
///
/// The throttle needs more than safety: **anything drawing on one provider budget must share one
/// ``RTSRAGRateGovernor``**, or each copy probes upward on its own 429s and together they exceed a
/// budget neither can see. Sharing the whole embedder achieves that, but the governor is the actual
/// unit and it is injectable — two embedders differing only in `dimensions` or `batchSize` draw on
/// one budget and should share one governor while keeping their own identities. See that type for
/// why the scope is (key, model) rather than the key.
///
/// A `final class` rather than an `actor` — an actor would not serialise anything here, since
/// actors are reentrant and an ingest suspends constantly. Everything a run accumulates still lives
/// in its own call frame, which is what keeps two runtimes genuinely independent.
public final class RTSRAGRetrievalRuntime: @unchecked Sendable {

    private let embedder: any RTSRAGEmbedding
    private let store: any RTSRAGVectorStore
    private let emitter = RTSRAGIngestEventEmitter()
    /// Held for the duration of one ``ingest(loader:chunker:scope:)``.
    ///
    /// A `Mutex` over a flag rather than making the runtime an `actor`, because an actor would not
    /// serialise these calls at all: actors are **reentrant**, so isolation is released at every
    /// `await` — and an ingest awaits the loader, the embedder and the store constantly. A second
    /// call would enter at the first suspension and interleave exactly as it does without one.
    private let isIngesting = Mutex(false)

    /// Live progress. Subscribe before calling ``ingest(loader:chunker:scope:)``.
    ///
    /// The runtime outlives any single ingest, so subscription belongs at setup and does not race
    /// the run — unlike a per-run object, where an event emitted before anyone attached would be
    /// lost. Delivery is asynchronous and order-preserving; see ``RTSRAGIngestEventEmitter``.
    public var eventPublisher: AnyPublisher<RTSRAGIngestEvent, Never> {
        emitter.publisher
    }

    public init(
        embedder: any RTSRAGEmbedding,
        store: any RTSRAGVectorStore
    ) {
        self.embedder = embedder
        self.store = store
    }

    // MARK: - Ingest

    /// Reads, chunks, embeds and stores everything `loader` produces.
    ///
    /// **One ingest at a time per runtime.** A second concurrent call throws
    /// ``RTSRAGError/ingestAlreadyRunning`` without touching the loader, the embedder, the store or
    /// the event stream — it cannot disturb the run already in progress. Concurrency comes from a
    /// second runtime over the same embedder and store.
    ///
    /// **Then sweeps orphans.** Once the loader has been read to the end, stored documents under
    /// its root — in this `scope` — that the run did not see are removed: a file that moved away,
    /// a page or row that is gone. Documents a sanitizer dropped, and sources that failed to load,
    /// are kept. A run that throws or is cancelled sweeps nothing. See `docs/rag-orphan-sweep.md`.
    ///
    /// - Parameter sweepsOrphans: `false` skips the sweep for this run.
    /// - Throws: ``RTSRAGError/ingestAlreadyRunning`` if this runtime is already ingesting; or,
    ///   once running, when the *embedder* is unusable — an exhausted account, an unavailable
    ///   model — or when the store was built by a different embedder. Per-document problems are
    ///   reported as events and counted in the returned stats; they do not end the run. Nor does a
    ///   failed sweep, which is counted in ``RTSRAGIngestionStats/sweepFailures``.
    @discardableResult
    public func ingest(
        loader: any RTSRAGDocumentLoader,
        chunker: any RTSRAGChunker,
        scope: RTSRAGStoreScope? = nil,
        sweepsOrphans: Bool = true
    ) async throws -> RTSRAGIngestionStats {
        // Ordering is load-bearing: the claim throws *before* the `defer` is installed, so a
        // refused second call cannot release the slot the first one holds. Written the other way
        // round, losing the race would end the running ingest's exclusivity.
        try claimIngestSlot()
        defer {
            isIngesting.withLock { $0 = false }
        }

        // Before the loader opens a file. The store would reject a foreign embedder on its first
        // write anyway, but by then a document has been read, chunked and *paid to embed* — and on
        // a metered provider that is real money for a run that cannot succeed.
        try await verifyEmbedderMatchesStore()

        var stats = RTSRAGIngestionStats()
        var seen = Set<RTSRAGDocumentID>()

        do {
            // Held rather than iterated inline: after the loop, the sweep reads what the stream
            // covered and what it recorded as filtered or failed.
            let stream = try loader.stream()
            for await element in stream {
                try Task.checkCancellation()
                switch element {
                case .failure(let error):
                    emitter.emit(.loadFailed(error))
                case .success(let document):
                    stats.documentsLoaded += 1
                    emitter.emit(.documentLoaded(id: document.id, source: document.source))
                    // A repeat inside one call means a non-unique `idColumn` or `idKey`: every
                    // record sharing that value collapses onto one id, and all but the last are
                    // embedded and then overwritten. A legitimate update arrives in a *later* call,
                    // never this one, so this is unambiguous.
                    if !seen.insert(document.id).inserted {
                        ragLog.warning(
                            "📚 \(document.source ?? "a document") repeats id \(document.id) in one ingest — check the id column; earlier copies will be overwritten"
                        )
                    }
                    let outcome = try await ingestOne(
                        document,
                        chunker: chunker,
                        scope: scope,
                        into: &stats
                    )
                    record(outcome, for: document, into: &stats)
                }
            }
            // Only a run that read its loader to the end may sweep: a thrown run never gets here,
            // and a cancellation that landed after the last element is checked for explicitly.
            if sweepsOrphans, let root = stream.root, !Task.isCancelled {
                await sweepOrphans(
                    under: RTSRAGSourceRoot(root),
                    seen: seen,
                    stream: stream,
                    scope: scope,
                    into: &stats
                )
            }
        } catch {
            // Drained on the way out too, not only on success — and `defer` cannot `await`.
            // Delivery is asynchronous, so without this the throw overtakes the events that explain
            // it and a subscriber sees the run stop with the failure still in flight behind it.
            // The failing path is the one where that ordering matters most.
            await emitter.drain()
            throw error
        }
        await emitter.drain()
        return stats
    }

    /// Removes every stored document whose source is `url`, or lies inside it — in `scope`.
    ///
    /// For what the automatic sweep cannot decide: that a file was **deleted**. The sweep cannot
    /// tell a deleted file from one the app merely lost access to, and never covers a file outside
    /// the root it was given. Works on a path that no longer exists, which is the point.
    ///
    /// - Returns: how many documents were removed. Each is announced as
    ///   ``RTSRAGIngestEvent/documentSwept(id:source:)``.
    @discardableResult
    public func removeSource(
        at url: URL,
        scope: RTSRAGStoreScope? = nil
    ) async throws -> Int {
        let stored = try await store.documents(under: RTSRAGSourceRoot(url), scope: scope)
        for (id, source) in stored.sorted(by: { $0.value < $1.value }) {
            try await store.deleteDocument(id: id)
            emitter.emit(.documentSwept(id: id, source: source))
        }
        await emitter.drain()
        return stored.count
    }

    /// The orphan sweep: lists what the store holds under `root` and removes what the run left
    /// orphaned, by ``RTSRAGOrphanSweep``'s rule.
    ///
    /// Never throws. The ingest has already succeeded, and an orphan that survives a failed sweep
    /// is swept by the next run — so a failure is logged and counted, not raised.
    private func sweepOrphans(
        under root: RTSRAGSourceRoot,
        seen: Set<RTSRAGDocumentID>,
        stream: RTSRAGDocumentStream,
        scope: RTSRAGStoreScope?,
        into stats: inout RTSRAGIngestionStats
    ) async {
        let stored: [RTSRAGDocumentID: String]
        do {
            stored = try await store.documents(under: root, scope: scope)
        } catch {
            ragLog.warning("📚 orphan sweep could not list \(root.path): \(error)")
            stats.sweepFailures += 1
            return
        }
        let orphans = RTSRAGOrphanSweep.orphans(
            stored: stored,
            seen: seen,
            filtered: stream.ledger.filteredDocuments,
            failedSources: stream.ledger.failedSources
        )
        for orphan in orphans {
            do {
                try await store.deleteDocument(id: orphan.id)
                stats.documentsSwept += 1
                emitter.emit(.documentSwept(id: orphan.id, source: orphan.source))
            } catch {
                ragLog.warning("📚 orphan sweep could not remove \(orphan.source): \(error)")
                stats.sweepFailures += 1
            }
        }
    }

    /// What happened to one document — one case per way `ingestOne` can end.
    ///
    /// Returned rather than recorded in place, so that **every** exit has to name an outcome and a
    /// bare `return` does not compile. ``record(_:for:into:)`` is then the single place a counter
    /// is applied and an event emitted, so the two cannot drift.
    private enum DocumentOutcome {
        case skipped
        case empty
        case committed(stored: Int, dropped: Int)
        case withheld(reason: String)
        case unchunkable(reason: String)
        case unembeddable(dropped: Int)
    }

    private func ingestOne(
        _ document: RTSRAGDocument,
        chunker: any RTSRAGChunker,
        scope: RTSRAGStoreScope?,
        into stats: inout RTSRAGIngestionStats
    ) async throws -> DocumentOutcome {
        var document = document
        document.contentHash = RTSRAGContentHash.of(document.content)

        if try await isStoredAndComplete(document) {
            return .skipped
        }

        let chunks: [RTSRAGChunk]
        do {
            chunks = try await chunker.chunk(document)
        } catch {
            return .unchunkable(reason: "\(error)")
        }
        // **Not** a `replaceDocument` with an empty array, which the store reads as a delete. A
        // document that chunks to nothing — an emptied file, a sanitizer that dropped everything —
        // leaves its stored version alone, matching Python's `if not chunks: return`. Deleting on
        // absence would make an unrelated sanitizer change quietly destructive; an intentional
        // delete goes through `deleteDocument`, which says so.
        guard !chunks.isEmpty else {
            return .empty
        }
        stats.chunksCreated += chunks.count
        emitter.emit(.documentChunked(id: document.id, chunks: chunks.count))

        let stamped = RTSRAGChunk.stamped(chunks, from: document)
        var embedded: [RTSRAGEmbeddedChunk] = []
        var droppedChunks = 0
        var withheldReason: String?

        for outcome in try await embedder.embed(stamped) {
            switch outcome {
            case .embedded(let batch, let metrics):
                embedded.append(contentsOf: batch)
                stats.chunksEmbedded += batch.count
                stats.record(metrics)
                emitter.emit(.batchEmbedded(id: document.id, chunks: batch.count, metrics: metrics))
            case .failed(let failure):
                stats.batchesFailed += 1
                stats.failures.append(failure)
                emitter.emit(.batchFailed(failure))
                if failure.kind == .invalidInput {
                    droppedChunks += failure.chunks.count
                } else {
                    withheldReason = withheldReason ?? "\(failure.kind): \(failure.underlying)"
                }
            }
        }

        // A failure a later run might not hit means this document is *incomplete by accident*, so
        // nothing is written and the previous version survives whole. Committing part of it would
        // reproduce the state Python leaves behind, where a failed batch mid-document has already
        // deleted the old version and written half the new one.
        if let withheldReason {
            // Transient by elimination: `.invalidInput` became a dropped chunk above, and the two
            // kinds that `endsTheRun` threw out of `embed` rather than reaching this loop — so what
            // is left is a rate limit or a 5xx, which a later run may well clear.
            return .withheld(reason: withheldReason)
        }
        // The degenerate end of the commit rule: every chunk was permanently rejected, so there is
        // no reduced document to commit. Carries its own drop count, since `commit` — the only
        // other place one is recorded — is never reached from here.
        guard !embedded.isEmpty else {
            return .unembeddable(dropped: droppedChunks)
        }
        return try await commit(embedded, of: document, dropped: droppedChunks, scope: scope)
    }

    /// Applies one document's outcome to the stats and announces it.
    ///
    /// The single place either happens, so the two cannot drift apart and no outcome can be
    /// recorded in one but not the other.
    private func record(
        _ outcome: DocumentOutcome,
        for document: RTSRAGDocument,
        into stats: inout RTSRAGIngestionStats
    ) {
        switch outcome {
        case .skipped:
            stats.documentsSkipped += 1
            emitter.emit(.documentSkipped(id: document.id, source: document.source))
        case .empty:
            stats.documentsEmpty += 1
            emitter.emit(.documentEmpty(id: document.id, source: document.source))
        case .committed(let stored, let dropped):
            stats.documentsCommitted += 1
            stats.chunksStored += stored
            stats.chunksDropped += dropped
            emitter.emit(.documentCommitted(id: document.id, stored: stored, dropped: dropped))
        case .withheld(let reason):
            stats.documentsWithheld += 1
            emitter.emit(.documentWithheld(id: document.id, reason: .transient(reason: reason)))
        case .unchunkable(let reason):
            stats.documentsUnchunkable += 1
            emitter.emit(.documentWithheld(id: document.id, reason: .unchunkable(reason: reason)))
        case .unembeddable(let dropped):
            stats.documentsUnembeddable += 1
            stats.chunksDropped += dropped
            emitter.emit(.documentWithheld(id: document.id, reason: .unembeddable(chunksDropped: dropped)))
        }
    }

    private func commit(
        _ embedded: [RTSRAGEmbeddedChunk],
        of document: RTSRAGDocument,
        dropped: Int,
        scope: RTSRAGStoreScope?
    ) async throws -> DocumentOutcome {
        // Stamped as the number **stored**, not the number chunked. Recording the larger figure
        // would make the completeness check below false for ever, so an unchanged document with one
        // permanently-unembeddable chunk would re-ingest and re-fail on every single run. This one
        // line is what makes dropping a chunk terminate instead of churn.
        let total = embedded.count
        let entries = embedded.map { embedded -> RTSRAGStoreEntry in
            // Rebuilt rather than mutated: `RTSRAGEmbeddedChunk.chunk` is a `let`, which is the
            // right call — an embedded chunk should not be editable once its vector is attached,
            // since changing the text would leave the vector describing something else.
            var chunk = embedded.chunk
            chunk.metadata[RTSRAGChunk.MetadataKey.documentChunkCount] = .integer(total)
            return RTSRAGStoreEntry(
                embedded: RTSRAGEmbeddedChunk(
                    chunk: chunk,
                    vector: embedded.vector,
                    embeddingModel: embedded.embeddingModel,
                    embeddingVersion: embedded.embeddingVersion
                ),
                scope: scope
            )
        }
        try await store.replaceDocument(id: document.id, with: entries)
        return .committed(stored: total, dropped: dropped)
    }

    // MARK: - Retrieve

    /// Embeds `query` and returns the closest stored chunks.
    ///
    /// The identity guard runs here too, and not only on ingest. The store rejects a query vector
    /// of the wrong *width*, but width is a weak proxy for the vector space: an on-device 512 and
    /// `text-embedding-3-small` truncated to 512 dimensions pass that check and mean completely
    /// different things, producing scores that look reasonable and rank nothing.
    ///
    /// Querying with the wrong embedder is also the *likelier* mistake of the two — the ingest is
    /// long finished, and nothing about the query looks wrong.
    public func retrieve(
        _ query: String,
        topK: Int = 5,
        filters: RTSRAGMetadata? = nil,
        scope: RTSRAGStoreScope? = nil
    ) async throws -> RTSRAGRetrievalResult {
        try await verifyEmbedderMatchesStore()
        let vectors = try await embedder.embed([query]).vectors
        guard let embedding = vectors.first else {
            throw RTSRAGError.embeddingFailed(reason: "the embedder returned no vector for the query")
        }
        let hits = try await store.search(
            RTSRAGStoreQuery(
                text: query,
                embedding: embedding,
                topK: topK,
                metadataFilters: filters,
                scope: scope
            )
        )
        return RTSRAGRetrievalResult(query: query, entries: hits)
    }

    // MARK: - Internals

    /// Takes the ingest slot, or throws because someone else holds it.
    ///
    /// Test and set inside one lock acquisition, so two calls racing to start cannot both claim it.
    private func claimIngestSlot() throws {
        try isIngesting.withLock { running in
            guard !running else {
                throw RTSRAGError.ingestAlreadyRunning
            }
            running = true
        }
    }

    /// Fails before any work when the store holds vectors from a different embedder.
    private func verifyEmbedderMatchesStore() async throws {
        // One entry is enough — `RTSRAGVectorStore` requires every entry an instance exposes to
        // share one model, and both shipped stores enforce it on write. An empty store has no
        // model at all, so there is nothing to compare and the next ingest establishes it.
        guard let existing = try await store.find(matching: [:], limit: 1).first else {
            return
        }
        guard existing.embeddingModel == embedder.modelIdentifier else {
            throw RTSRAGError.embeddingModelMismatch(
                expected: existing.embeddingModel,
                found: embedder.modelIdentifier
            )
        }
    }

    /// Whether the store already holds this document, at this content, in full.
    ///
    /// Three conditions, and the third is the one that matters: matching the source and hash proves
    /// the *content* is unchanged, while comparing against the recorded chunk count proves the last
    /// write actually finished. Without it a document left short by an interrupted run would be
    /// mistaken for complete and never repaired.
    private func isStoredAndComplete(_ document: RTSRAGDocument) async throws -> Bool {
        guard let source = document.source, let hash = document.contentHash else {
            return false
        }
        let filters: RTSRAGMetadata = [
            RTSRAGChunk.MetadataKey.sourcePath: .string(source),
            RTSRAGChunk.MetadataKey.contentHash: .string(hash),
        ]
        guard let sample = try await store.find(matching: filters, limit: 1).first,
              case .integer(let expected)? = sample.metadata[RTSRAGChunk.MetadataKey.documentChunkCount]
        else {
            return false
        }
        return try await store.count(matching: filters) >= expected
    }
}
