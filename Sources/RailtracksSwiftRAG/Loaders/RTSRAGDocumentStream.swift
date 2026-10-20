//
//  RTSRAGDocumentStream.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation
import Synchronization

// MARK: - RTSRAGDocumentStream

/// A lazy stream of loaded documents, one source at a time.
///
/// **Not an `AsyncThrowingStream`, deliberately.** Its `Continuation.yield` never suspends, so it
/// either buffers without bound — putting a whole corpus in memory — or drops elements, which for
/// ingest is silent data loss. Neither is acceptable, and the pressure is guaranteed: reading a
/// file takes microseconds while embedding it takes network round trips, so a producer left
/// unchecked runs far ahead of its consumer.
///
/// Doing the work in `next()` makes laziness structural instead — nothing is read until the
/// consumer asks for it. That is Python's one stated loader invariant, "implementations must not
/// buffer the full corpus before yielding", which its own `CSVLoader` breaks by materialising
/// every row before the first yield.
///
/// Every file-based loader is "a list of sources plus how to turn one into documents", so they all
/// share this one iterator rather than each wiring up their own.
public struct RTSRAGDocumentStream: AsyncSequence, Sendable {
    public typealias Element = Result<RTSRAGDocument, RTSRAGError>

    /// The sources to read, in the order they should be emitted. Resolved up front — enumerating a
    /// directory is cheap, and knowing the full list is what lets a caller report progress.
    private let sources: [URL]
    /// Turns one source into its documents. May produce several — a CSV file yields one per row.
    private let loadOne: @Sendable (URL) async throws -> [RTSRAGDocument]
    /// What one run of this stream covers — the file or folder the loader was pointed at — and so
    /// what an orphan sweep may clear: stored documents under it that the run did not see.
    ///
    /// `nil`, the default, means the stream claims to cover nothing, and no sweep follows it. That
    /// keeps a custom loader safe until it states a root deliberately. See
    /// `docs/rag-orphan-sweep.md`.
    public let root: URL?
    /// What the stream read but did not emit — sources that failed, documents a transform removed.
    /// Both protect stored documents from a sweep. Shared with every iterator and every stream
    /// ``mapDocuments(_:)`` derives, so it sees the whole run whichever layer did the dropping.
    let ledger: RTSRAGStreamLedger

    /// - Parameter root: the file or folder this stream covers, for the orphan sweep. Leave it
    ///   `nil` unless every document under it would be emitted by a complete run.
    public init(
        sources: [URL],
        root: URL? = nil,
        loadOne: @escaping @Sendable (URL) async throws -> [RTSRAGDocument]
    ) {
        self.init(sources: sources, root: root, ledger: RTSRAGStreamLedger(), loadOne: loadOne)
    }

    private init(
        sources: [URL],
        root: URL?,
        ledger: RTSRAGStreamLedger,
        loadOne: @escaping @Sendable (URL) async throws -> [RTSRAGDocument]
    ) {
        self.sources = sources
        self.root = root
        self.ledger = ledger
        self.loadOne = loadOne
    }

    /// How many sources this stream will read.
    ///
    /// The denominator for "file N of M" progress, which is the reason ``sources`` is resolved in
    /// `stream()` rather than discovered while iterating. Not a document count — a source may
    /// produce many documents (a CSV row each) or none at all.
    public var sourceCount: Int {
        sources.count
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(sources: sources, ledger: ledger, loadOne: loadOne)
    }

    /// A stream that applies `transform` to each source's documents before they are emitted.
    ///
    /// Composes at the *source* level rather than per document, so a transform can drop or add
    /// documents, and so laziness is preserved — `transform` runs when its source is read, not
    /// ahead of time. This is what lets ``RTSRAGSanitizingLoader`` decorate any loader without
    /// reaching into it.
    ///
    /// Every document id `transform` removes is recorded as *filtered*, which protects its stored
    /// version from the orphan sweep: a document a sanitizer dropped still exists at its source,
    /// and deleting it on absence would make an unrelated sanitizer change quietly destructive.
    /// The root carries over, since the derived stream reads the same sources.
    public func mapDocuments(
        _ transform: @escaping @Sendable ([RTSRAGDocument]) async throws -> [RTSRAGDocument]
    ) -> RTSRAGDocumentStream {
        let loadOne = self.loadOne
        let ledger = self.ledger
        return RTSRAGDocumentStream(sources: sources, root: root, ledger: ledger) { url in
            let loaded = try await loadOne(url)
            let kept = try await transform(loaded)
            let keptIDs = Set(kept.map(\.id))
            ledger.recordFiltered(loaded.map(\.id).filter { !keptIDs.contains($0) })
            return kept
        }
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let sources: [URL]
        private let ledger: RTSRAGStreamLedger
        private let loadOne: @Sendable (URL) async throws -> [RTSRAGDocument]
        private var sourceIndex = 0
        /// Documents from the source currently being drained. Only ever holds one source's worth,
        /// which is the smallest unit a file can be read in.
        private var pending: [RTSRAGDocument] = []
        private var pendingIndex = 0

        init(
            sources: [URL],
            ledger: RTSRAGStreamLedger,
            loadOne: @escaping @Sendable (URL) async throws -> [RTSRAGDocument]
        ) {
            self.sources = sources
            self.ledger = ledger
            self.loadOne = loadOne
        }

        public mutating func next() async -> Element? {
            while true {
                if pendingIndex < pending.count {
                    let document = pending[pendingIndex]
                    pendingIndex += 1
                    return .success(document)
                }
                guard sourceIndex < sources.count else {
                    return nil
                }
                let source = sources[sourceIndex]
                sourceIndex += 1
                do {
                    // Logged *before* the read, so a source that stalls — an enormous PDF, a
                    // network volume that went away — is named by the last line in the log. A log
                    // after the fact only ever reports sources that already succeeded.
                    ragLog.debug("📚 loading \(source.path)")
                    pending = try await loadOne(source)
                    pendingIndex = 0
                    // The count is what makes an empty source visible. It emits no elements, so
                    // without this line a file that yielded nothing reads exactly like one that
                    // was never opened.
                    ragLog.debug("📚 loaded \(pending.count) document(s) from \(source.path)")
                } catch {
                    // One unreadable source does not end the stream — the next iteration moves on
                    // to the following source. This is the departure from Python, where a single
                    // failing file aborts the whole ingestion run.
                    let failure = RTSRAGError.asLoadFailure(error, source: source.path)
                    // Unreadable is not gone: whatever is stored for this source must survive the
                    // orphan sweep, which cannot tell a missing file from a failing one.
                    ledger.recordFailed(source)
                    // Warning rather than error: the caller receives this as a `.failure` element
                    // and decides what it means, so this is a notice, not a verdict. Warning is
                    // also above swift-log's default level, unlike the two `debug` lines above —
                    // a skipped source should not pass silently in an ordinary run.
                    ragLog.warning("📚 \(failure)")
                    pending = []
                    pendingIndex = 0
                    return .failure(failure)
                }
                // A source that produced nothing (an empty file, every row filtered) loops round
                // to the next rather than emitting anything.
            }
        }
    }
}

// MARK: - RTSRAGStreamLedger

/// What one run of a stream read without emitting: the inputs to the orphan sweep's protections.
///
/// A class shared by reference, because the stream is a value that is copied into iterators and
/// wrapped by ``RTSRAGDocumentStream/mapDocuments(_:)`` — and the runtime has to read, after the
/// run, what any of those layers recorded during it.
final class RTSRAGStreamLedger: Sendable {

    private struct State {
        var failedSources: Set<URL> = []
        var filteredDocuments: Set<RTSRAGDocumentID> = []
    }

    private let state = Mutex(State())

    /// Sources whose read threw — every stored document under one is kept.
    var failedSources: Set<URL> {
        state.withLock { $0.failedSources }
    }

    /// Documents a transform removed before they were emitted — kept, since they still exist.
    var filteredDocuments: Set<RTSRAGDocumentID> {
        state.withLock { $0.filteredDocuments }
    }

    func recordFailed(_ source: URL) {
        state.withLock { _ = $0.failedSources.insert(source) }
    }

    func recordFiltered(_ ids: [RTSRAGDocumentID]) {
        guard !ids.isEmpty else {
            return
        }
        state.withLock { $0.filteredDocuments.formUnion(ids) }
    }
}

// MARK: - Error adaptation

extension RTSRAGError {
    /// Wraps an arbitrary loading error as a `.loadFailed` carrying its source.
    ///
    /// Already-typed errors pass through unchanged so a loader can report something more specific
    /// than "could not read" without it being flattened.
    static func asLoadFailure(_ error: Error, source: String) -> RTSRAGError {
        if let ragError = error as? RTSRAGError {
            return ragError
        }
        return .loadFailed(source: source, reason: "\(error)")
    }
}
