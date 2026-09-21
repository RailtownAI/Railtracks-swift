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
    /// Not written, because something failed in a way a later run may not. The previous version
    /// stays intact rather than being half-replaced.
    case documentWithheld(id: RTSRAGDocumentID, reason: String)
    /// A source the loader could not read. One file, not the run.
    case loadFailed(RTSRAGError)
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
        deliveryQueue.async { [subject] in
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
