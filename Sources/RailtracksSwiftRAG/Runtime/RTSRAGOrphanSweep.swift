//
//  RTSRAGOrphanSweep.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-30.
//

import Foundation

/// Which stored documents an ingest run leaves orphaned — the rule both runtimes apply.
///
/// Pure, so the rule is tested once and cannot drift between the vector-store and Spotlight paths;
/// each runtime only lists what its store holds and deletes what this returns. The rule and its
/// reasoning are in `docs/rag-orphan-sweep.md`.
enum RTSRAGOrphanSweep {

    /// One document to remove.
    struct Orphan: Equatable {
        let id: RTSRAGDocumentID
        let source: String
    }

    /// Stored documents under the run's root that the run neither saw nor had reason to keep.
    ///
    /// - Parameters:
    ///   - stored: what the store holds under the root, by document, with its source.
    ///   - seen: every document the run loaded, whatever became of it.
    ///   - filtered: documents a transform dropped before they were emitted — they still exist.
    ///   - failedSources: sources the run could not read — unreadable is not gone, so everything
    ///     under one is kept.
    /// - Returns: orphans sorted by source, so deletion and its events run in a stable order.
    static func orphans(
        stored: [RTSRAGDocumentID: String],
        seen: Set<RTSRAGDocumentID>,
        filtered: Set<RTSRAGDocumentID>,
        failedSources: Set<URL>
    ) -> [Orphan] {
        let failedRoots = failedSources.map(RTSRAGSourceRoot.init)
        return stored
            .filter { id, source in
                !seen.contains(id)
                    && !filtered.contains(id)
                    && !failedRoots.contains { $0.contains(source: source) }
            }
            .map { Orphan(id: $0.key, source: $0.value) }
            .sorted { $0.source < $1.source }
    }
}
