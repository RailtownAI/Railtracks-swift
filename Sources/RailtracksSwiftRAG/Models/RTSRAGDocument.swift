//
//  RTSRAGDocument.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

// MARK: - RTSRAGDocumentID

/// Identifies a document across ingests.
///
/// Stability is the whole point: updating a document works by replacing every entry carrying this
/// id, so an id that changed between runs would orphan the previous version's chunks rather than
/// replace them. See ``RTSRAGDocument/init(content:type:source:metadata:)``.
public struct RTSRAGDocumentID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

// MARK: - RTSRAGDocumentType

/// The content format of a document, as reported by the loader that produced it.
public enum RTSRAGDocumentType: String, Sendable, Codable {
    case text
    case markdown
    case pdf
    case csv
    case json
    case jsonLines = "jsonl"
}

// MARK: - RTSRAGDocument

/// A unit of source content produced by a loader, before chunking.
///
/// "Document" is whatever a loader chooses to emit, not necessarily a file. That choice is the
/// main lever over update cost: an edit re-embeds the whole document, so splitting a large file
/// into per-section documents makes edits cheap, at the price of chunks that cannot reach across
/// a section boundary for context.
public struct RTSRAGDocument: Sendable, Hashable, Codable {
    /// The decoded textual content. Always a string — binary loaders decode their own input.
    public let content: String
    public let type: RTSRAGDocumentType
    /// Where this document came from: a file path, a URI, or a relational id. `nil` for content
    /// constructed in memory.
    ///
    /// Load-bearing beyond provenance — it derives ``id`` and, with ``contentHash``, decides
    /// whether a re-ingest is a skip or a replace.
    public let source: String?
    public let id: RTSRAGDocumentID
    public let metadata: RTSRAGMetadata
    /// SHA-256 of ``content``, set by the ingest pipeline rather than the loader. Answers "has
    /// *this source* changed?" — never "does this content exist elsewhere?", which is why two
    /// copies of one file under different sources are ingested twice by design.
    public internal(set) var contentHash: String?

    /// - Parameters:
    ///   - source: When given, ``id`` is derived from it deterministically, so the same source
    ///     yields the same id across processes and an update can find the prior version to
    ///     replace. When `nil`, a random id is minted and the document has **no update
    ///     semantics** — re-ingesting it adds a second copy rather than replacing the first.
    public init(
        content: String,
        type: RTSRAGDocumentType = .text,
        source: String? = nil,
        metadata: RTSRAGMetadata = [:]
    ) {
        self.content = content
        self.type = type
        self.source = source
        self.metadata = metadata
        self.contentHash = nil
        if let source {
            self.id = RTSRAGDocumentID(RTSRAGDocument.derivedID(for: source))
        } else {
            self.id = RTSRAGDocumentID(UUID())
        }
    }

    /// An explicit id, for a loader that already has a stable identifier of its own.
    public init(
        content: String,
        type: RTSRAGDocumentType = .text,
        source: String?,
        id: RTSRAGDocumentID,
        metadata: RTSRAGMetadata = [:]
    ) {
        self.content = content
        self.type = type
        self.source = source
        self.id = id
        self.metadata = metadata
        self.contentHash = nil
    }
}
