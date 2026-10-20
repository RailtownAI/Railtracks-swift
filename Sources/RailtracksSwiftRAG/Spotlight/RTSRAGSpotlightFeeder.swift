//
//  RTSRAGSpotlightFeeder.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-28.
//

import CoreSpotlight
import Foundation

/// Donates a document's chunks to a Core Spotlight index, and answers whether they are there.
///
/// The Spotlight counterpart of an ``RTSRAGVectorStore``, with one difference that shapes the rest:
/// **Spotlight embeds, not us.** The feeder hands over text and attributes; there is no vector and
/// no embedder, so it is a sink for ``RTSRAGSpotlightIngestRuntime`` rather than a store the
/// retrieval runtime could query.
///
/// ## Items
///
/// One `CSSearchableItem` per chunk, identified by ``RTSRAGChunk/positionalIdentifier`` and grouped
/// under the domain `"<namespace>.<documentID>"`. Domain deletion is recursive, which is what makes
/// both ``deleteDocument(id:)`` and ``deleteAll()`` a single call that touches nothing else the app
/// donates.
///
/// ## Replacement is two calls, not one operation
///
/// ``replaceDocument(id:with:)`` deletes the document's domain and then indexes the new items. The
/// delete is not optional — positional ids overwrite in place, so a document that shrank from five
/// chunks to three would otherwise keep its old `#3` and `#4`. Both calls return once Spotlight has
/// *journaled* the request, not applied it, so unlike
/// ``RTSRAGVectorStore/replaceDocument(id:with:)`` this is not atomic: the failure it permits is a
/// document briefly missing, never one that mixes two versions.
///
/// ## Donated chunks are visible system-wide
///
/// Every chunk becomes its own result in the device's Spotlight search (⌘Space on macOS), titled
/// `<source name>` — `report.pdf#page-3` for a PDF page — with its passage text as the
/// description. Observed on macOS 27; no mechanism has been found that keeps an item queryable by
/// the app but out of the system search UI. Weigh that before donating anything sensitive: a
/// document ingested for retrieval becomes browsable, fragment by fragment, by anyone at the
/// device.
///
/// A `struct` rather than an actor: it holds no mutable state, and actor isolation would not
/// serialise a replacement anyway, since isolation is released at the `await` between its two
/// calls.
public struct RTSRAGSpotlightFeeder: Sendable {

    public static let defaultNamespace = "railtracks.rag"

    /// The prefix of every domain this feeder writes, and the scope of ``deleteAll()``.
    public let namespace: String
    /// Stamped on every item donated. See ``init(index:namespace:expirationDate:)``.
    public let expirationDate: Date
    private let indexing: any RTSRAGSpotlightIndexing

    /// - Parameters:
    ///   - index: where to donate. The default index unless told otherwise, because whether
    ///     `SpotlightSearchTool` can see a *named* index is undocumented, and it has to see this
    ///     one.
    ///   - namespace: distinguishes this feeder's items from anything else the app donates, and
    ///     from another feeder's. Domains are hierarchical on `.`, so give two feeders namespaces
    ///     where neither is a prefix of the other — with `app` and `app.rag`, the first one's
    ///     ``deleteAll()`` would remove both.
    ///   - expirationDate: when Spotlight may drop the donated items. Defaults to never, because
    ///     the alternative is not "no expiry" but the system's own: unset, items expire after an
    ///     undocumented period and a corpus the app believes is indexed quietly empties. Donations
    ///     persist across launches, so nothing re-donates them unless a source changes. A
    ///     re-donation resets the date, since it replaces the items.
    public init(
        index: CSSearchableIndex = .default(),
        namespace: String = RTSRAGSpotlightFeeder.defaultNamespace,
        expirationDate: Date = .distantFuture
    ) {
        let adapter = RTSRAGSpotlightIndexAdapter(searchableIndex: index)
        self.init(indexing: adapter, namespace: namespace, expirationDate: expirationDate)
    }

    /// For tests: any ``RTSRAGSpotlightIndexing``, including an in-memory one.
    init(
        indexing: any RTSRAGSpotlightIndexing,
        namespace: String = RTSRAGSpotlightFeeder.defaultNamespace,
        expirationDate: Date = .distantFuture
    ) {
        self.indexing = indexing
        self.namespace = namespace
        self.expirationDate = expirationDate
    }

    // MARK: - Writes

    /// Replaces everything donated for `id` with `chunks`.
    ///
    /// An empty `chunks` is a delete, matching the vector stores — but
    /// ``RTSRAGSpotlightIngestRuntime`` never sends one, since a document that chunks to nothing is
    /// left as it was.
    public func replaceDocument(
        id: RTSRAGDocumentID,
        with chunks: [RTSRAGChunk]
    ) async throws {
        try await deleteDocument(id: id)
        guard !chunks.isEmpty else {
            return
        }
        let items = RTSRAGSpotlightItem.items(
            for: chunks,
            of: id,
            namespace: namespace,
            expirationDate: expirationDate
        )
        try await indexing.index(items)
    }

    public func deleteDocument(id: RTSRAGDocumentID) async throws {
        let domain = RTSRAGSpotlightItem.domainIdentifier(for: id, namespace: namespace)
        try await indexing.deleteItems(inDomains: [domain])
    }

    /// Removes every item this feeder's namespace holds, and nothing else the app donated.
    public func deleteAll() async throws {
        try await indexing.deleteItems(inDomains: [namespace])
    }

    // MARK: - Searching

    /// A Spotlight query predicate matching only this feeder's items.
    ///
    /// For a caller's own search — `CSSearchQueryContext.filterQueries` or
    /// `CSUserQueryContext.filterQueries` — so results cannot include anything else the app
    /// donates. Offered here rather than left for the caller to spell, because the attribute it
    /// filters on is this module's own and its name is not public.
    public var searchFilter: String {
        let key = RTSRAGSpotlightAttribute.namespace.rawValue
        return "\(key) == \"\(RTSRAGSpotlightFeeder.escapedQueryValue(namespace))\""
    }

    // MARK: - Listing

    /// Every document this feeder donated whose source lies under `root`, with its source.
    ///
    /// What the orphan sweep and `removeSource(at:)` delete from. Spotlight has no tenant scope, so
    /// the feeder's namespace is the scope. See ``RTSRAGSourceRoot`` for the matching rule.
    public func documents(under root: RTSRAGSourceRoot) async throws -> [RTSRAGDocumentID: String] {
        let records = try await indexing.records(
            matching: RTSRAGSpotlightFeeder.listingQuery(namespace: namespace, root: root)
        )
        var found: [RTSRAGDocumentID: String] = [:]
        for record in records {
            // Re-checked here as well as in the query: the wildcard is Spotlight's, and a document
            // is only deleted on this module's own reading of the rule.
            guard let id = record.documentID,
                  let source = record.sourcePath,
                  root.contains(source: source)
            else {
                continue
            }
            found[id] = source
        }
        return found
    }

    /// `namespace == … && (source == path || source == "path#*" || source == "path/*" || …)`, over
    /// every one of the root's ``RTSRAGSourceRoot/spellings``.
    ///
    /// Each path is escaped as a literal, and only the trailing `*` is left unescaped, as the
    /// wildcard.
    static func listingQuery(
        namespace: String,
        root: RTSRAGSourceRoot
    ) -> String {
        let key = RTSRAGSpotlightAttribute.sourcePath.rawValue
        let sources = root.spellings.flatMap { spelling in
            let path = escapedQueryValue(spelling)
            return [
                "\(key) == \"\(path)\"",
                "\(key) == \"\(path)#*\"",
                "\(key) == \"\(path)/*\"",
            ]
        }
        let namespaceKey = RTSRAGSpotlightAttribute.namespace.rawValue
        let scope = "\(namespaceKey) == \"\(escapedQueryValue(namespace))\""
        return "\(scope) && (\(sources.joined(separator: " || ")))"
    }

    // MARK: - Staleness

    /// Whether Spotlight already holds this source, at this content, in full.
    ///
    /// The rule ``RTSRAGRetrievalRuntime`` applies to its store, asked of Spotlight instead: the
    /// source and content hash prove the *content* is unchanged, and comparing the number of
    /// matching items with the chunk count each one records proves the last donation finished.
    ///
    /// Answered by Spotlight rather than a local ledger, through a query predicate over custom
    /// attributes with the chunk count read back via `fetchAttributes`. A query that finds nothing
    /// means "not stored", and the document is donated again.
    public func isStoredAndComplete(
        source: String,
        contentHash: String
    ) async throws -> Bool {
        let records = try await indexing.records(
            matching: RTSRAGSpotlightFeeder.stalenessQuery(
                namespace: namespace,
                source: source,
                contentHash: contentHash
            )
        )
        guard let expected = records.lazy.compactMap(\.chunkCount).first else {
            return false
        }
        return records.count >= expected
    }

    /// `namespace == … && source == … && hash == …`, over the custom attributes.
    static func stalenessQuery(
        namespace: String,
        source: String,
        contentHash: String
    ) -> String {
        [
            (RTSRAGSpotlightAttribute.namespace, namespace),
            (RTSRAGSpotlightAttribute.sourcePath, source),
            (RTSRAGSpotlightAttribute.contentHash, contentHash),
        ]
        .map { attribute, value in
            "\(attribute.rawValue) == \"\(escapedQueryValue(value))\""
        }
        .joined(separator: " && ")
    }

    /// Escapes a value for a Spotlight query string literal.
    ///
    /// Backslash and quote would end the literal early, and `*` is a wildcard in Spotlight's query
    /// syntax — so a source path containing one would match more than itself.
    static func escapedQueryValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
    }
}
