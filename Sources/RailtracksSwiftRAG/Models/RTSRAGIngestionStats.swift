//
//  RTSRAGIngestionStats.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-21.
//

import Foundation

/// What one ingest did.
///
/// Every field is derivable from ``RTSRAGIngestEvent``, and a test pins that. The return value is
/// therefore a convenience for the common case — call, await, read the totals — rather than a
/// second source of truth that could disagree with the event stream.
public struct RTSRAGIngestionStats: Sendable {

    /// Documents the loader produced, before any decision about them.
    public var documentsLoaded = 0
    /// Unchanged since the last ingest and already complete in the store, so never embedded.
    public var documentsSkipped = 0
    public var documentsCommitted = 0
    /// Not written, because a failure that a later run might not hit left them incomplete. Their
    /// previous versions are intact.
    public var documentsWithheld = 0
    /// Not written, and a later run will refuse them identically: no chunks could be made of them.
    ///
    /// **Disjoint from ``documentsWithheld``**, which counts the transient refusals. A chunker is a
    /// pure function of its input, so a document it rejects is rejected the same way for ever — the
    /// fix is a different chunker for that source, not another attempt. It needs its own count
    /// because a chunker refusal records no ``failures`` entry, so nothing else would notice it.
    public var documentsUnchunkable = 0
    /// Chunked, but every chunk was permanently rejected by the embedder, so nothing was left to
    /// write.
    ///
    /// The degenerate end of the commit rule: one bad chunk in 512 is dropped and the document
    /// committed without it, but when *all* of them are rejected there is no reduced document to
    /// commit. Permanent, and it churns — nothing is stored, so the staleness check cannot skip it.
    public var documentsUnembeddable = 0
    /// Produced no chunks at all — an emptied file, or a sanitizer that dropped everything.
    ///
    /// Not a failure, which is why it stays out of ``needsAttention``: a legitimately empty source
    /// is indistinguishable from a misconfigured sanitizer, and flagging the first to catch the
    /// second would cry wolf on every blank file. Counted so the second is at least visible.
    public var documentsEmpty = 0

    public var chunksCreated = 0
    public var chunksEmbedded = 0
    public var chunksStored = 0
    /// Embeddable chunks lost to a permanent failure, whose documents were committed without them.
    ///
    /// Separate from ``chunksEmbedded`` because it is the number worth acting on: a run with
    /// dropped chunks has content in the corpus that retrieval can never return.
    public var chunksDropped = 0

    public var batchesFailed = 0
    /// Kept whole rather than counted, because the chunks and the provider's message are what make
    /// a failure actionable — see ``RTSRAGEmbeddingFailure``.
    public var failures: [RTSRAGEmbeddingFailure] = []

    /// Stored documents the orphan sweep removed after the run. Not a terminal outcome of anything
    /// loaded — a swept document was, by definition, not in this run — so it stays out of
    /// ``documentsAccountedFor``.
    public var documentsSwept = 0
    /// Orphans the sweep found but could not remove, or `1` when listing them failed. They remain
    /// for the next run; the ingest itself had already succeeded.
    public var sweepFailures = 0

    /// Tokens the provider billed, when it reports them. `nil` on a path that bills nothing, which
    /// is every on-device run.
    public var inputTokens: Int?
    /// Time spent inside the embedder, not wall-clock for the run.
    public var embeddingLatency: TimeInterval = 0

    public init() {
    }

    /// Whether **anything went wrong** in this run — not the stronger "retrying will not help",
    /// since ``failures`` holds transient failures too.
    ///
    /// ``documentsEmpty`` is the deliberate omission: an empty source is legitimate, and is
    /// indistinguishable from a misconfigured sanitizer.
    ///
    /// The terms are an enumeration rather than a minimal expression — only ``documentsUnchunkable``
    /// can be the deciding one, since every other outcome here also left an entry in ``failures``.
    public var needsAttention: Bool {
        chunksDropped > 0
            || documentsUnchunkable > 0
            || documentsUnembeddable > 0
            || documentsWithheld > 0
            || !failures.isEmpty
    }

    /// The six terminal outcomes, which **must** sum to ``documentsLoaded`` for a run that
    /// completes.
    ///
    /// The qualifier matters: a run-ending embedder failure throws with a document already counted
    /// as loaded and no outcome reached. Nothing observes that, since the throw means no stats are
    /// returned — but asserting the invariant anywhere but a completed run would be wrong.
    ///
    /// A shortfall means some path returned without recording an outcome.
    public var documentsAccountedFor: Int {
        documentsSkipped
            + documentsCommitted
            + documentsWithheld
            + documentsUnchunkable
            + documentsUnembeddable
            + documentsEmpty
    }

    mutating func record(_ metrics: RTSRAGEmbeddingMetrics) {
        if let tokens = metrics.inputTokens {
            inputTokens = (inputTokens ?? 0) + tokens
        }
        embeddingLatency += metrics.latency
    }
}
