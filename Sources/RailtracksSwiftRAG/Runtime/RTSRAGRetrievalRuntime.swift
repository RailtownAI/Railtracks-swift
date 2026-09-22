//
//  RTSRAGRetrievalRuntime.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-21.
//

import Combine
import Foundation

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
/// ## No per-run state
///
/// A `final class` rather than an `actor`, holding only the embedder, the store and the emitter —
/// all immutable. Everything a run accumulates lives in its own call frame. That is what lets two
/// ingests proceed as genuinely independent runs sharing two actors, instead of serialising on the
/// runtime or racing its counters.
public final class RTSRAGRetrievalRuntime: @unchecked Sendable {

    private let embedder: any RTSRAGEmbedding
    private let store: any RTSRAGVectorStore
    private let emitter = RTSRAGIngestEventEmitter()

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
    /// - Throws: when the *embedder* is unusable — an exhausted account, an unavailable model — or
    ///   when the store was built by a different embedder. Per-document problems are reported as
    ///   events and counted in the returned stats; they do not end the run.
    @discardableResult
    public func ingest(
        loader: any RTSRAGDocumentLoader,
        chunker: any RTSRAGChunker,
        scope: RTSRAGStoreScope? = nil
    ) async throws -> RTSRAGIngestionStats {
        // Before the loader opens a file. The store would reject a foreign embedder on its first
        // write anyway, but by then a document has been read, chunked and *paid to embed* — and on
        // a metered provider that is real money for a run that cannot succeed.
        try await verifyEmbedderMatchesStore()

        var stats = RTSRAGIngestionStats()
        var seen = Set<RTSRAGDocumentID>()

        do {
            for await element in try loader.stream() {
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
                    try await ingestOne(document, chunker: chunker, scope: scope, into: &stats)
                }
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

    private func ingestOne(
        _ document: RTSRAGDocument,
        chunker: any RTSRAGChunker,
        scope: RTSRAGStoreScope?,
        into stats: inout RTSRAGIngestionStats
    ) async throws {
        var document = document
        document.contentHash = RTSRAGContentHash.of(document.content)

        if try await isStoredAndComplete(document) {
            stats.documentsSkipped += 1
            emitter.emit(.documentSkipped(id: document.id, source: document.source))
            return
        }

        let chunks: [RTSRAGChunk]
        do {
            chunks = try await chunker.chunk(document)
        } catch {
            stats.documentsWithheld += 1
            emitter.emit(.documentWithheld(id: document.id, reason: "\(error)"))
            return
        }
        // **Not** a `replaceDocument` with an empty array, which the store reads as a delete. A
        // document that chunks to nothing — an emptied file, a sanitizer that dropped everything —
        // leaves its stored version alone, matching Python's `if not chunks: return`. Deleting on
        // absence would make an unrelated sanitizer change quietly destructive; an intentional
        // delete goes through `deleteDocument`, which says so.
        guard !chunks.isEmpty else {
            return
        }
        stats.chunksCreated += chunks.count
        emitter.emit(.documentChunked(id: document.id, chunks: chunks.count))

        let stamped = stamp(chunks, from: document)
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
            stats.documentsWithheld += 1
            emitter.emit(.documentWithheld(id: document.id, reason: withheldReason))
            return
        }
        guard !embedded.isEmpty else {
            return
        }
        try await commit(embedded, of: document, dropped: droppedChunks, scope: scope, into: &stats)
    }

    private func commit(
        _ embedded: [RTSRAGEmbeddedChunk],
        of document: RTSRAGDocument,
        dropped: Int,
        scope: RTSRAGStoreScope?,
        into stats: inout RTSRAGIngestionStats
    ) async throws {
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
        stats.documentsCommitted += 1
        stats.chunksStored += total
        stats.chunksDropped += dropped
        emitter.emit(.documentCommitted(id: document.id, stored: total, dropped: dropped))
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

    /// Fails before any work when the store holds vectors from a different embedder.
    private func verifyEmbedderMatchesStore() async throws {
        // One entry is enough — every entry in a store shares its model, which is exactly what the
        // store's own write guard enforces. An empty store has nothing to compare, so the first
        // ingest establishes the model.
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

    /// Writes the staleness metadata every later run reads back.
    private func stamp(_ chunks: [RTSRAGChunk], from document: RTSRAGDocument) -> [RTSRAGChunk] {
        chunks.map { chunk in
            var chunk = chunk
            if let source = document.source {
                chunk.metadata[RTSRAGChunk.MetadataKey.sourcePath] = .string(source)
            }
            if let hash = document.contentHash {
                chunk.metadata[RTSRAGChunk.MetadataKey.contentHash] = .string(hash)
            }
            return chunk
        }
    }
}
