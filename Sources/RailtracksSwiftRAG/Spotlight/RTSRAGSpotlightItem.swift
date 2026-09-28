//
//  RTSRAGSpotlightItem.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-28.
//

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - RTSRAGSpotlightAttribute

/// The custom Spotlight attributes a donated chunk carries, beyond Apple's predefined ones.
///
/// They are the staleness metadata the pipeline already stamps — source, content hash, chunk
/// count — plus the feeder's namespace, so a staleness query cannot match another feeder's items
/// for the same source.
///
/// Searchable, so the staleness check can put them in a query predicate, but **not searchable by
/// default**, so a hash or a path never matches someone's ordinary text search.
///
/// Built on demand rather than held as `static let`s: `CSCustomAttributeKey` is an Objective-C
/// class that is not `Sendable`, and a key is cheap to make.
enum RTSRAGSpotlightAttribute: String, CaseIterable {
    case namespace = "rtsragNamespace"
    case sourcePath = "rtsragSourcePath"
    case contentHash = "rtsragContentHash"
    case chunkCount = "rtsragChunkCount"

    /// The key the attribute is written and read under.
    ///
    /// Force-unwrapped because the only failure is an invalid key name, and these are fixed,
    /// alphanumeric literals — a `nil` here is a typo in this file, caught by the first test run.
    var key: CSCustomAttributeKey {
        CSCustomAttributeKey(
            keyName: rawValue,
            searchable: true,
            searchableByDefault: false,
            unique: false,
            multiValued: false
        )!
    }
}

// MARK: - RTSRAGSpotlightItem

/// One chunk as Spotlight will hold it, before it becomes a `CSSearchableItem`.
///
/// A value type rather than the `CSSearchableItem` itself, for two reasons. `CSSearchableItem` is
/// not `Sendable`, so it cannot cross into the index adapter's concurrency domain; and a plain
/// struct is what lets the feeder's tests assert on exactly what would be donated without
/// Spotlight.
struct RTSRAGSpotlightItem: Sendable, Equatable {
    /// ``RTSRAGChunk/positionalIdentifier`` — stable across re-ingest, unlike the chunk's id.
    let uniqueIdentifier: String
    /// `"<namespace>.<documentID>"`. Domain deletion is recursive, so deleting this deletes the
    /// document and deleting the namespace deletes every document.
    let domainIdentifier: String
    let documentID: RTSRAGDocumentID
    let chunkIndex: Int
    let chunkCount: Int
    let namespace: String
    let textContent: String
    let sourcePath: String?
    let contentHash: String?
    /// A display name for the source — its last path component when it looks like a path.
    let containerTitle: String?
    /// Set only when the source is a file that exists, so a record id is never presented as a
    /// location. A PDF page's `#page-N` source resolves to the PDF.
    let contentURL: URL?
    /// When Spotlight may drop the item. Always set: left unset, the system expires items after an
    /// undocumented period, and donated chunks would vanish without anything noticing.
    let expirationDate: Date

    /// The `CSSearchableItem` to donate.
    ///
    /// The *containment* attributes carry the chunk's parent and position — document id, index,
    /// source name — which is the relationship Spotlight defines them for.
    func searchableItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.textContent = textContent
        attributes.title = containerTitle
        attributes.containerIdentifier = documentID.description
        attributes.containerOrder = NSNumber(value: chunkIndex)
        attributes.containerTitle = containerTitle
        attributes.contentURL = contentURL
        attributes.setValue(
            namespace as NSString,
            forCustomKey: RTSRAGSpotlightAttribute.namespace.key
        )
        attributes.setValue(
            NSNumber(value: chunkCount),
            forCustomKey: RTSRAGSpotlightAttribute.chunkCount.key
        )
        if let sourcePath {
            attributes.setValue(
                sourcePath as NSString,
                forCustomKey: RTSRAGSpotlightAttribute.sourcePath.key
            )
        }
        if let contentHash {
            attributes.setValue(
                contentHash as NSString,
                forCustomKey: RTSRAGSpotlightAttribute.contentHash.key
            )
        }
        let item = CSSearchableItem(
            uniqueIdentifier: uniqueIdentifier,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = expirationDate
        return item
    }
}

// MARK: - Building items

extension RTSRAGSpotlightItem {
    /// The domain every item of `documentID` is donated under.
    static func domainIdentifier(
        for documentID: RTSRAGDocumentID,
        namespace: String
    ) -> String {
        "\(namespace).\(documentID)"
    }

    /// One item per chunk of a single document.
    ///
    /// The chunk count is the number of chunks given, not a stamped figure: the feeder donates a
    /// document's chunks all together or not at all, so there is no partial commit whose size
    /// could differ from it.
    static func items(
        for chunks: [RTSRAGChunk],
        of documentID: RTSRAGDocumentID,
        namespace: String,
        expirationDate: Date = .distantFuture
    ) -> [RTSRAGSpotlightItem] {
        let source = stringValue(chunks.first?.metadata[RTSRAGChunk.MetadataKey.sourcePath])
        let contentURL = source.flatMap(existingFileURL)
        let containerTitle = source.map(displayName)
        let domain = domainIdentifier(for: documentID, namespace: namespace)
        return chunks.map { chunk in
            RTSRAGSpotlightItem(
                uniqueIdentifier: chunk.positionalIdentifier,
                domainIdentifier: domain,
                documentID: documentID,
                chunkIndex: chunk.index,
                chunkCount: chunks.count,
                namespace: namespace,
                textContent: chunk.content,
                sourcePath: source,
                contentHash: stringValue(chunk.metadata[RTSRAGChunk.MetadataKey.contentHash]),
                containerTitle: containerTitle,
                contentURL: contentURL,
                expirationDate: expirationDate
            )
        }
    }

    private static func stringValue(_ value: RTSRAGMetadataValue?) -> String? {
        guard case .string(let string)? = value else {
            return nil
        }
        return string
    }

    /// A file URL for `source` when it names a file that exists, else `nil`.
    ///
    /// Checked rather than assumed, because a source is not always a path: a CSV record's source
    /// carries its row, and a caller's own loader may use any id.
    ///
    /// A PDF page's source is `"<path>#page-N"`, so when the whole source is not a file, the part
    /// before its last `#` is tried too — every page then points at its PDF. The whole source goes
    /// first because `#` is legal in a file name, and a file actually called `notes#1.txt` must not
    /// be mistaken for a fragment of `notes`.
    private static func existingFileURL(_ source: String) -> URL? {
        if let url = fileURL(ifExists: source) {
            return url
        }
        guard let fragmentStart = source.lastIndex(of: "#") else {
            return nil
        }
        return fileURL(ifExists: String(source[..<fragmentStart]))
    }

    private static func fileURL(ifExists path: String) -> URL? {
        let url = path.hasPrefix("file://") ? URL(string: path) : URL(fileURLWithPath: path)
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func displayName(_ source: String) -> String {
        let name = (source as NSString).lastPathComponent
        return name.isEmpty ? source : name
    }
}
