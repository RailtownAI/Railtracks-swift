//
//  RTSRAGSanitizingLoader.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

// MARK: - RTSRAGSanitizer

/// Transforms — or discards — a document on its way out of a loader.
///
/// No policy is built in; the caller supplies it. Typical uses are redacting PII before content
/// reaches an embedding provider *and* a store, stripping repeated headers that would otherwise
/// dominate similarity, and normalising whitespace.
///
/// - Important: this is a **filter as well as a transform**. Returning `nil` drops the document
///   from the stream entirely, which is more power than the name suggests — a dropped document is
///   harder to diagnose than a failed one, because nothing downstream ever sees it.
public protocol RTSRAGSanitizer: Sendable {
    /// The document to keep, or `nil` to drop it.
    func sanitize(_ document: RTSRAGDocument) async throws -> RTSRAGDocument?
}

// MARK: - RTSRAGSanitizingLoader

/// Wraps another loader, passing every document through a sanitizer.
///
/// Reads nothing itself, and is format-agnostic by construction: it operates on
/// ``RTSRAGDocument``, which every loader produces regardless of whether it came from a PDF page,
/// a CSV row or a text file.
///
/// ```swift
/// RTSRAGSanitizingLoader(
///     wrapping: RTSRAGTextLoader(path: contractsDirectory),
///     sanitizer: redactor
/// )
/// ```
///
/// **It runs once per document, before chunking**, and that ordering is the point: a PII span or a
/// boilerplate footer can straddle a chunk boundary, so a per-chunk transform would only ever see
/// half of one. Running here also means N invocations rather than one per chunk.
public struct RTSRAGSanitizingLoader<Wrapped: RTSRAGDocumentLoader>: RTSRAGDocumentLoader {
    private let wrapped: Wrapped
    private let sanitizer: any RTSRAGSanitizer

    public init(
        wrapping wrapped: Wrapped,
        sanitizer: any RTSRAGSanitizer
    ) {
        self.wrapped = wrapped
        self.sanitizer = sanitizer
    }

    public func stream() throws -> RTSRAGDocumentStream {
        let sanitizer = self.sanitizer
        // Composed through `mapDocuments`, so the inner loader is still drained one source at a
        // time and this holds no more in memory than the loader it wraps.
        return try wrapped.stream().mapDocuments { documents in
            var kept: [RTSRAGDocument] = []
            for document in documents {
                // A throwing sanitizer surfaces as a `.failure` for the source being read, not as
                // a thrown error. `next()` is non-throwing, so there is nowhere for it to
                // propagate to — and since a misconfigured sanitizer is wrong for every document,
                // it produces a failure per source and no documents at all, which is loud enough
                // to be unmistakable.
                guard let sanitized = try await sanitizer.sanitize(document) else {
                    let origin = document.source ?? "an unsourced document"
                    ragLog.debug("📚 sanitizer dropped \(origin)")
                    continue
                }
                kept.append(sanitized)
            }
            return kept
        }
    }
}
