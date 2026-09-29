//
//  RTSRAGSpotlightSearcher.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-29.
//

import CoreSpotlight
import Foundation

// MARK: - RTSRAGSpotlightHit

/// One chunk a Spotlight search found, with the passage and where it came from.
public struct RTSRAGSpotlightHit: Sendable, Hashable {
    /// The item's ``RTSRAGChunk/positionalIdentifier``, `"<documentID>#<index>"`.
    public let identifier: String
    public let documentID: RTSRAGDocumentID?
    public let chunkIndex: Int?
    /// The chunk's passage. Read from `contentDescription`, since Spotlight never returns the
    /// `textContent` it matches against.
    public let text: String
    /// The document's full source — `"<path>#page-N"` for a PDF page — which is what a citation
    /// needs. `nil` when the donated chunk had none.
    public let source: String?
    /// A display name for the source.
    public let title: String?
    /// The source file, when it existed at donation time.
    public let contentURL: URL?
    /// Position in the results, from zero. `CSUserQuery` returns ranked items but no score, so
    /// arrival order is the only ordering there is.
    public let rank: Int

    public init(
        identifier: String,
        documentID: RTSRAGDocumentID?,
        chunkIndex: Int?,
        text: String,
        source: String?,
        title: String?,
        contentURL: URL?,
        rank: Int
    ) {
        self.identifier = identifier
        self.documentID = documentID
        self.chunkIndex = chunkIndex
        self.text = text
        self.source = source
        self.title = title
        self.contentURL = contentURL
        self.rank = rank
    }
}

// MARK: - RTSRAGSpotlightSearcher

/// Searches what an ``RTSRAGSpotlightFeeder`` donated, with `CSUserQuery`.
///
/// ```swift
/// let searcher = RTSRAGSpotlightSearcher(feeder: feeder)
/// let hits = try await searcher.search("refund window", limit: 5)
/// ```
///
/// Lives beside the feeder because correct retrieval depends on conventions only the feeder knows:
/// results are limited to its namespace; the passage comes back through `contentDescription`,
/// because `textContent` is index-only; and the citation-ready source is a custom attribute.
///
/// ## What to expect from the matching
///
/// On the configurations tried so far `CSUserQuery` has matched by **keyword only**: a query that
/// shares no words or word prefixes with a passage finds nothing, with semantic search enabled or
/// not. Results carry no score, and Spotlight returns nothing rather than a weak best guess. A
/// caller that needs meaning-based retrieval should put a model in front — one that turns a
/// question into the words the documents use — or keep a vector store alongside.
public struct RTSRAGSpotlightSearcher: Sendable {

    /// The ``RTSRAGSpotlightFeeder/searchFilter`` of the feeder whose items to search.
    private let filter: String

    public init(feeder: RTSRAGSpotlightFeeder) {
        self.filter = feeder.searchFilter
    }

    /// The chunks matching `query`, best first.
    ///
    /// - Parameters:
    ///   - limit: the most results to return.
    ///   - usesSemanticSearch: `false` restricts matching to keywords. See the type's notes on
    ///     what `true` has actually delivered.
    /// - Throws: whatever the query reports. Cancelling the calling task cancels the query.
    public func search(
        _ query: String,
        limit: Int = 10,
        usesSemanticSearch: Bool = true
    ) async throws -> [RTSRAGSpotlightHit] {
        guard !query.isEmpty, limit > 0 else {
            return []
        }
        let context = RTSRAGSpotlightSearcher.makeContext(
            filter: filter,
            limit: limit,
            usesSemanticSearch: usesSemanticSearch
        )
        let running = RunningQuery(CSUserQuery(userQueryString: query, userQueryContext: context))
        return try await withTaskCancellationHandler {
            var hits: [RTSRAGSpotlightHit] = []
            for try await response in running.query.responses {
                guard case .item(let found) = response else {
                    continue
                }
                hits.append(RTSRAGSpotlightSearcher.hit(from: found.item, rank: hits.count))
            }
            return hits
        } onCancel: {
            running.query.cancel()
        }
    }

    /// Lets the cancellation handler reach the query it has to stop.
    ///
    /// `@unchecked` because `CSUserQuery` is not `Sendable`, and the handler runs concurrently
    /// with the loop reading `responses`. The only cross-thread use is `cancel()`, which exists
    /// precisely to end a running query from outside it.
    private final class RunningQuery: @unchecked Sendable {
        let query: CSUserQuery

        init(_ query: CSUserQuery) {
            self.query = query
        }
    }

    // MARK: - Query

    static func makeContext(
        filter: String,
        limit: Int,
        usesSemanticSearch: Bool
    ) -> CSUserQueryContext {
        let context = CSUserQueryContext()
        context.enableRankedResults = true
        context.maxResultCount = limit
        context.disableSemanticSearch = !usesSemanticSearch
        // Only this feeder's items, not anything else the app donates.
        context.filterQueries = [filter]
        // Without these a hit is little more than its identifier. `contentDescription`, not
        // `textContent`: the query matches `textContent`, but Spotlight never returns it.
        context.fetchAttributes = [
            "title",
            "contentDescription",
            "containerIdentifier",
            "containerTitle",
            "containerOrder",
            "contentURL",
            RTSRAGSpotlightAttribute.sourcePath.rawValue,
        ]
        return context
    }

    /// Maps a returned item onto a hit. Separate so it can be tested with hand-built items.
    static func hit(from item: CSSearchableItem, rank: Int) -> RTSRAGSpotlightHit {
        let attributes = item.attributeSet
        let source = attributes.value(forCustomKey: RTSRAGSpotlightAttribute.sourcePath.key)
        let documentID = attributes.containerIdentifier
            .flatMap(UUID.init(uuidString:))
            .map(RTSRAGDocumentID.init)
        return RTSRAGSpotlightHit(
            identifier: item.uniqueIdentifier,
            documentID: documentID,
            chunkIndex: attributes.containerOrder?.intValue,
            text: attributes.contentDescription ?? "",
            source: source as? String,
            title: attributes.containerTitle ?? attributes.title,
            contentURL: attributes.contentURL,
            rank: rank
        )
    }
}
