//
//  ProgressLoader.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-21.
//

import Foundation
import RailtracksSwiftRAG

/// Wraps any loader and reports each source as it finishes.
///
/// The runtime drives the loader itself, so per-*file* progress — "file 3 of 12" — is no longer
/// something the caller can count in its own loop. It comes from here instead:
/// `RTSRAGDocumentStream.mapDocuments` runs the transform **once per source** with that source's
/// documents, which is exactly the boundary the UI wants and needs no path parsing to find.
///
/// Worth noting what this demonstrates beyond the progress bar: a loader is decorable by anything,
/// not just `RTSRAGSanitizingLoader`. The seam holds for an app's own purposes.
struct ProgressLoader: RTSRAGDocumentLoader {

    private let wrapped: any RTSRAGDocumentLoader
    private let onSourceFinished: @Sendable ([RTSRAGDocument]) async -> Void

    init(
        wrapping wrapped: any RTSRAGDocumentLoader,
        onSourceFinished: @escaping @Sendable ([RTSRAGDocument]) async -> Void
    ) {
        self.wrapped = wrapped
        self.onSourceFinished = onSourceFinished
    }

    func stream() throws -> RTSRAGDocumentStream {
        let onSourceFinished = self.onSourceFinished
        return try wrapped.stream().mapDocuments { documents in
            await onSourceFinished(documents)
            return documents
        }
    }
}
