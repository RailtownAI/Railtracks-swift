//
//  RTSRAGIngestEvent.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-21.
//

import Combine
import Foundation

// MARK: - RTSRAGIngestEvent

/// What an ingest reports as it runs.
///
/// Deliberately richer than the Python engine's, which emits `BatchIngested`, `DocumentFailed` and
/// `DocumentSkipped` but counts `documents_loaded` and `chunks_created` internally — so its own
/// event stream cannot reconstruct its own `IngestionStats`. Emitting those two as well means a
/// subscriber that never sees the return value can still account for a run, which is what makes
/// ``RTSRAGIngestionStats`` a convenience rather than a separate source of truth.
public enum RTSRAGIngestEvent: Sendable {
    /// A document arrived from the loader. Emitted before any decision about it.
    case documentLoaded(id: RTSRAGDocumentID, source: String?)
    /// The store already holds this document at this content hash, complete, so nothing was
    /// embedded. The saving this event reports is the whole point of the staleness check.
    case documentSkipped(id: RTSRAGDocumentID, source: String?)
    case documentChunked(id: RTSRAGDocumentID, chunks: Int)
    case batchEmbedded(id: RTSRAGDocumentID, chunks: Int, metrics: RTSRAGEmbeddingMetrics)
    case batchFailed(RTSRAGEmbeddingFailure)
    /// Written to the store. `dropped` counts chunks left out because they were permanently
    /// unembeddable — the document is complete as it can be, not as it was chunked.
    case documentCommitted(id: RTSRAGDocumentID, stored: Int, dropped: Int)
    /// Not written. The previous version stays intact rather than being half-replaced.
    case documentWithheld(id: RTSRAGDocumentID, reason: RTSRAGWithholdReason)
    /// Chunked to nothing, so there was never anything to write — an emptied file, or a sanitizer
    /// that dropped the whole document. Not a failure, and distinct from
    /// ``documentSkipped(id:source:)``, which means the store already holds it.
    case documentEmpty(id: RTSRAGDocumentID, source: String?)
    /// A source the loader could not read. One file, not the run.
    case loadFailed(RTSRAGError)
}

// MARK: - RTSRAGWithholdReason

/// Why a document was not written — three outcomes that call for different responses.
///
/// The distinction is not academic: telling someone to retry a document no chunker will ever
/// accept is the advice that wastes the most time.
public enum RTSRAGWithholdReason: Sendable {
    /// An embedding failure a later run may well clear — a rate limit, a 5xx. Retrying is the
    /// right response.
    case transient(reason: String)
    /// The chunker refused the document. A chunker is a pure function of its input, so every later
    /// run refuses it identically; only a different chunker for that source helps.
    case unchunkable(reason: String)
    /// Every chunk was permanently rejected by the embedder, leaving nothing to write. Carries the
    /// chunk count so the event stream can still account for the run on its own.
    case unembeddable(chunksDropped: Int)
}

// MARK: - RTSRAGIngestEventEmitter

/// Publishes ingest events without letting a subscriber slow the ingest down.
///
/// A direct port of `RTSEventEmitter`'s isolation, for reasons that module learned the hard way:
/// `PassthroughSubject.send` delivers **synchronously on the calling thread**, so anything a
/// subscriber does would otherwise land on the ingest's critical path — a SwiftUI update, a disk
/// write, a network call.
///
/// So `emit` hands the event to a serial queue and returns. Serial, never a `Task` per event:
/// unordered dispatch is the race `docs/duplicate-node-id.md` documents, and an event stream whose
/// order does not match emission order is worse than none for reading a pipeline.
///
/// The cost is asynchronous delivery — an event may arrive after the call that produced it has
/// returned. ``drain()`` exists so a test can wait for the backlog rather than sleep.
final class RTSRAGIngestEventEmitter: @unchecked Sendable {

    private let subject = PassthroughSubject<RTSRAGIngestEvent, Never>()
    /// Serial, so delivery order matches emission order.
    private let deliveryQueue = DispatchQueue(label: "ai.railtown.railtracks.rag.ingest.events")

    var publisher: AnyPublisher<RTSRAGIngestEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    func emit(_ event: RTSRAGIngestEvent) {
        // `self`, not `subject`: `PassthroughSubject` is not `Sendable`, and the subject is only ever
        // touched on `deliveryQueue` — the confinement this type's `@unchecked Sendable` stands for.
        deliveryQueue.async { [self] in
            subject.send(event)
        }
    }

    /// Returns once every event emitted so far has been delivered.
    ///
    /// A barrier on the same serial queue, so it cannot jump the backlog. Needed because delivery
    /// is asynchronous: without it a test would assert on events that have not arrived yet, and
    /// sleeping instead would be slower and still flaky.
    func drain() async {
        await withCheckedContinuation { continuation in
            deliveryQueue.async {
                continuation.resume()
            }
        }
    }
}
