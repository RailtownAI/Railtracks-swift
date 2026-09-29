//
//  RTSRAGSpotlightIndexing.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-28.
//

import CoreSpotlight
import Foundation
import Synchronization

// MARK: - RTSRAGSpotlightRecord

/// What the staleness check and the orphan sweep need back from one matching item.
///
/// A value type for the same reason ``RTSRAGSpotlightItem`` is one: `CSSearchableItem` is not
/// `Sendable`, so the adapter converts inside its own callback rather than handing the item across.
struct RTSRAGSpotlightRecord: Sendable, Equatable {
    let uniqueIdentifier: String
    /// The recorded chunk count, or `nil` when the item did not come back with one.
    let chunkCount: Int?
    /// The owning document, from `containerIdentifier` — what a sweep deletes by.
    let documentID: RTSRAGDocumentID?
    /// The document's source, from the custom source-path attribute — what a sweep reports.
    let sourcePath: String?

    init(
        uniqueIdentifier: String,
        chunkCount: Int?,
        documentID: RTSRAGDocumentID? = nil,
        sourcePath: String? = nil
    ) {
        self.uniqueIdentifier = uniqueIdentifier
        self.chunkCount = chunkCount
        self.documentID = documentID
        self.sourcePath = sourcePath
    }
}

// MARK: - RTSRAGSpotlightIndexing

/// The three things the feeder asks of a Spotlight index.
///
/// Internal, and deliberately narrow: it exists so tests can substitute an in-memory index, not as
/// an extension point. The public seam is the `CSSearchableIndex` the feeder is constructed with.
protocol RTSRAGSpotlightIndexing: Sendable {
    func index(_ items: [RTSRAGSpotlightItem]) async throws
    func deleteItems(inDomains domainIdentifiers: [String]) async throws
    /// Items matching `queryString`, with their recorded chunk counts, documents and sources.
    func records(matching queryString: String) async throws -> [RTSRAGSpotlightRecord]
}

// MARK: - RTSRAGSpotlightIndexAdapter

/// ``RTSRAGSpotlightIndexing`` over a real `CSSearchableIndex`.
///
/// `@unchecked Sendable` because `CSSearchableIndex` is an Objective-C class without the
/// annotation. The adapter never mutates it — it only calls its indexing and deletion methods —
/// and holds nothing else.
struct RTSRAGSpotlightIndexAdapter: RTSRAGSpotlightIndexing, @unchecked Sendable {
    let searchableIndex: CSSearchableIndex

    func index(_ items: [RTSRAGSpotlightItem]) async throws {
        try await searchableIndex.indexSearchableItems(items.map { $0.searchableItem() })
    }

    func deleteItems(inDomains domainIdentifiers: [String]) async throws {
        try await searchableIndex.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers)
    }

    /// Runs a `CSSearchQuery`, fetching the chunk-count attribute for each hit.
    ///
    /// Not tied to ``searchableIndex``: a query searches the app's indexes as a whole, so a named
    /// index is found the same way as the default one. The handler-based API rather than the
    /// `results` sequence, because that sequence is newer than this package's OS floor.
    func records(matching queryString: String) async throws -> [RTSRAGSpotlightRecord] {
        let context = CSSearchQueryContext()
        context.fetchAttributes = [
            RTSRAGSpotlightAttribute.chunkCount.rawValue,
            RTSRAGSpotlightAttribute.sourcePath.rawValue,
            "containerIdentifier",
        ]
        let query = CSSearchQuery(queryString: queryString, queryContext: context)
        let found = Mutex<[RTSRAGSpotlightRecord]>([])
        query.foundItemsHandler = { items in
            let chunkCountKey = RTSRAGSpotlightAttribute.chunkCount.key
            let sourcePathKey = RTSRAGSpotlightAttribute.sourcePath.key
            let records = items.map { item in
                let attributes = item.attributeSet
                let chunkCount = attributes.value(forCustomKey: chunkCountKey) as? NSNumber
                let documentID = attributes.containerIdentifier
                    .flatMap(UUID.init(uuidString:))
                    .map(RTSRAGDocumentID.init)
                return RTSRAGSpotlightRecord(
                    uniqueIdentifier: item.uniqueIdentifier,
                    chunkCount: chunkCount?.intValue,
                    documentID: documentID,
                    sourcePath: attributes.value(forCustomKey: sourcePathKey) as? String
                )
            }
            found.withLock { $0.append(contentsOf: records) }
        }
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            query.completionHandler = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            query.start()
        }
        return found.withLock { $0 }
    }
}
