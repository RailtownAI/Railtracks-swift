//
//  RTSRAGSpotlightIngestRuntime.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-28.
//

import Combine
import Foundation
import Synchronization

/// Runs the Spotlight pipeline — loader → chunker → ``RTSRAGSpotlightFeeder`` — one document at a
/// time.
///
/// ```swift
/// let runtime = RTSRAGSpotlightIngestRuntime(feeder: RTSRAGSpotlightFeeder())
/// let stats = try await runtime.ingest(
///     loader: RTSRAGTextLoader(path: directory),
///     chunker: RTSRAGSentenceChunker()
/// )
/// ```
///
/// ``RTSRAGRetrievalRuntime``'s ingest loop without the embedding step, because Spotlight embeds
/// what it is given. Kept as its own type rather than generalising that runtime, so the
/// vector-store path is not refactored to make room for this one.
///
/// It keeps that loop's rules: one ingest per instance; per-item load failures reported, not
/// fatal; a warning when one ingest repeats a document id; an unchanged, completely donated
/// document skipped; a document that chunks to nothing left as it was; events drained on every
/// exit. It also reuses its types — ``RTSRAGIngestEvent`` and ``RTSRAGIngestionStats`` — whose
/// embedding-only cases and counters simply never occur here.
///
/// Retrieval is not this type's job. The donated chunks are found through Spotlight itself —
/// `SpotlightSearchTool` in a Foundation Models session, or a `CSSearchQuery`.
public final class RTSRAGSpotlightIngestRuntime: @unchecked Sendable {

    private let feeder: RTSRAGSpotlightFeeder
    private let emitter = RTSRAGIngestEventEmitter()
    /// Held for the duration of one ``ingest(loader:chunker:)``. A `Mutex` over a flag rather than
    /// an actor, for the reason ``RTSRAGRetrievalRuntime`` gives: an actor is reentrant at every
    /// `await`, so it would not serialise two ingests at all.
    private let isIngesting = Mutex(false)

    /// Live progress. Subscribe before calling ``ingest(loader:chunker:)``.
    public var eventPublisher: AnyPublisher<RTSRAGIngestEvent, Never> {
        emitter.publisher
    }

    public init(feeder: RTSRAGSpotlightFeeder) {
        self.feeder = feeder
    }

    // MARK: - Ingest

    /// Reads, chunks and donates everything `loader` produces, then sweeps orphans.
    ///
    /// The sweep follows the same rule as ``RTSRAGRetrievalRuntime``'s: once the loader has been
    /// read to the end, donated documents under its root that the run did not see are removed,
    /// keeping any a sanitizer dropped or whose source failed to load. The feeder's namespace is
    /// the scope. See `docs/rag-orphan-sweep.md`.
    ///
    /// - Parameter sweepsOrphans: `false` skips the sweep for this run.
    /// - Throws: ``RTSRAGError/ingestAlreadyRunning`` if this runtime is already ingesting, or when
    ///   the loader cannot start. Per-document problems — including a failed donation — are
    ///   reported as events and counted in the returned stats; they do not end the run. Nor does a
    ///   failed sweep, which is counted in ``RTSRAGIngestionStats/sweepFailures``.
    @discardableResult
    public func ingest(
        loader: any RTSRAGDocumentLoader,
        chunker: any RTSRAGChunker,
        sweepsOrphans: Bool = true
    ) async throws -> RTSRAGIngestionStats {
        // The claim throws before the `defer` is installed, so a refused second call cannot release
        // the slot the first one holds.
        try claimIngestSlot()
        defer {
            isIngesting.withLock { $0 = false }
        }

        var stats = RTSRAGIngestionStats()
        var seen = Set<RTSRAGDocumentID>()

        do {
            // Held rather than iterated inline, so the sweep can read what it covered and recorded.
            let stream = try loader.stream()
            for await element in stream {
                try Task.checkCancellation()
                switch element {
                case .failure(let error):
                    emitter.emit(.loadFailed(error))
                case .success(let document):
                    stats.documentsLoaded += 1
                    emitter.emit(.documentLoaded(id: document.id, source: document.source))
                    if !seen.insert(document.id).inserted {
                        ragLog.warning(
                            "📚 \(document.source ?? "a document") repeats id \(document.id) in one ingest — check the id column; earlier copies will be overwritten"
                        )
                    }
                    let outcome = try await ingestOne(document, chunker: chunker, into: &stats)
                    record(outcome, for: document, into: &stats)
                }
            }
            if sweepsOrphans, let root = stream.root, !Task.isCancelled {
                await sweepOrphans(
                    under: RTSRAGSourceRoot(root),
                    seen: seen,
                    stream: stream,
                    into: &stats
                )
            }
        } catch {
            // Drained on the way out too: delivery is asynchronous, so without it the throw would
            // overtake the events that explain it.
            await emitter.drain()
            throw error
        }
        await emitter.drain()
        return stats
    }

    /// Removes one document's chunks from Spotlight.
    public func deleteDocument(id: RTSRAGDocumentID) async throws {
        try await feeder.deleteDocument(id: id)
    }

    /// Removes every donated document whose source is `url`, or lies inside it.
    ///
    /// For a deleted file, which the automatic sweep cannot tell from one the app lost access to.
    /// Works on a path that no longer exists.
    ///
    /// - Returns: how many documents were removed, each announced as
    ///   ``RTSRAGIngestEvent/documentSwept(id:source:)``.
    @discardableResult
    public func removeSource(at url: URL) async throws -> Int {
        let donated = try await feeder.documents(under: RTSRAGSourceRoot(url))
        for (id, source) in donated.sorted(by: { $0.value < $1.value }) {
            try await feeder.deleteDocument(id: id)
            emitter.emit(.documentSwept(id: id, source: source))
        }
        await emitter.drain()
        return donated.count
    }

    /// The orphan sweep, by ``RTSRAGOrphanSweep``'s rule. Never throws — the ingest has already
    /// succeeded, and a surviving orphan is swept by the next run.
    private func sweepOrphans(
        under root: RTSRAGSourceRoot,
        seen: Set<RTSRAGDocumentID>,
        stream: RTSRAGDocumentStream,
        into stats: inout RTSRAGIngestionStats
    ) async {
        let donated: [RTSRAGDocumentID: String]
        do {
            donated = try await feeder.documents(under: root)
        } catch {
            ragLog.warning("📚 orphan sweep could not list \(root.path) in Spotlight: \(error)")
            stats.sweepFailures += 1
            return
        }
        let orphans = RTSRAGOrphanSweep.orphans(
            stored: donated,
            seen: seen,
            filtered: stream.ledger.filteredDocuments,
            failedSources: stream.ledger.failedSources
        )
        for orphan in orphans {
            do {
                try await feeder.deleteDocument(id: orphan.id)
                stats.documentsSwept += 1
                emitter.emit(.documentSwept(id: orphan.id, source: orphan.source))
            } catch {
                ragLog.warning("📚 orphan sweep could not remove \(orphan.source): \(error)")
                stats.sweepFailures += 1
            }
        }
    }

    /// Removes every chunk the feeder's namespace holds.
    public func deleteAll() async throws {
        try await feeder.deleteAll()
    }

    /// What happened to one document — one case per way ``ingestOne(_:chunker:into:)`` can end, so
    /// every exit has to name an outcome and ``record(_:for:into:)`` is the one place it is
    /// counted.
    private enum DocumentOutcome {
        case skipped
        case empty
        case committed(stored: Int)
        case withheld(reason: String)
        case unchunkable(reason: String)
    }

    private func ingestOne(
        _ document: RTSRAGDocument,
        chunker: any RTSRAGChunker,
        into stats: inout RTSRAGIngestionStats
    ) async throws -> DocumentOutcome {
        var document = document
        document.contentHash = RTSRAGContentHash.of(document.content)

        if await isStoredAndComplete(document) {
            return .skipped
        }

        let chunks: [RTSRAGChunk]
        do {
            chunks = try await chunker.chunk(document)
        } catch {
            return .unchunkable(reason: "\(error)")
        }
        // Not a replacement with nothing, which would delete the document: an emptied file or a
        // sanitizer that dropped everything leaves the donated version alone, as the vector-store
        // path does. An intentional delete goes through `deleteDocument`.
        guard !chunks.isEmpty else {
            return .empty
        }
        stats.chunksCreated += chunks.count
        emitter.emit(.documentChunked(id: document.id, chunks: chunks.count))

        // Every chunk is donated or none is, so the count stamped is the count chunked — there is
        // no partial commit whose size could differ from it, unlike the vector store's dropped
        // chunks.
        let stamped = RTSRAGChunk.stamped(chunks, from: document).map { chunk in
            var chunk = chunk
            chunk.metadata[RTSRAGChunk.MetadataKey.documentChunkCount] = .integer(chunks.count)
            return chunk
        }
        do {
            try await feeder.replaceDocument(id: document.id, with: stamped)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Transient by assumption: nothing here was rejected for its content, so a later run
            // may well succeed. Withheld rather than half-written — a delete that landed before the
            // index failed leaves the document missing, and the staleness check re-donates it.
            return .withheld(reason: "\(error)")
        }
        return .committed(stored: stamped.count)
    }

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
        case .committed(let stored):
            stats.documentsCommitted += 1
            stats.chunksStored += stored
            emitter.emit(.documentCommitted(id: document.id, stored: stored, dropped: 0))
        case .withheld(let reason):
            stats.documentsWithheld += 1
            emitter.emit(.documentWithheld(id: document.id, reason: .transient(reason: reason)))
        case .unchunkable(let reason):
            stats.documentsUnchunkable += 1
            emitter.emit(.documentWithheld(id: document.id, reason: .unchunkable(reason: reason)))
        }
    }

    // MARK: - Internals

    private func claimIngestSlot() throws {
        try isIngesting.withLock { running in
            guard !running else {
                throw RTSRAGError.ingestAlreadyRunning
            }
            running = true
        }
    }

    /// Whether Spotlight already holds this document, at this content, in full.
    ///
    /// A document without a source is never skipped — there is nothing stable to match it by. A
    /// query that *fails* is treated the same way, logged rather than thrown: the cost of being
    /// wrong is one re-donation, which the domain delete keeps free of duplicates, while throwing
    /// would end the whole ingest over a check that exists only to save work.
    private func isStoredAndComplete(_ document: RTSRAGDocument) async -> Bool {
        guard let source = document.source, let hash = document.contentHash else {
            return false
        }
        do {
            return try await feeder.isStoredAndComplete(source: source, contentHash: hash)
        } catch {
            ragLog.warning(
                "📚 Spotlight staleness check failed for \(source), re-donating: \(error)"
            )
            return false
        }
    }
}
