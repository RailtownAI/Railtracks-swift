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

    /// Tokens the provider billed, when it reports them. `nil` on a path that bills nothing, which
    /// is every on-device run.
    public var inputTokens: Int?
    /// Time spent inside the embedder, not wall-clock for the run.
    public var embeddingLatency: TimeInterval = 0

    public init() {
    }

    /// Whether anything in this run needs a human.
    ///
    /// Withheld documents resolve themselves on the next run; dropped chunks and failures do not.
    public var needsAttention: Bool {
        chunksDropped > 0 || !failures.isEmpty
    }

    mutating func record(_ metrics: RTSRAGEmbeddingMetrics) {
        if let tokens = metrics.inputTokens {
            inputTokens = (inputTokens ?? 0) + tokens
        }
        embeddingLatency += metrics.latency
    }
}
