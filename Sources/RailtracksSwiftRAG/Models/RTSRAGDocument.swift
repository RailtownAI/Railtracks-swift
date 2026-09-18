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
///
/// **Open rather than a closed enum, deliberately.** An app is expected to write its own loaders —
/// there is no format registry, the caller picks a loader by constructing it — so the set of
/// formats cannot be known here. A closed enum would force a `.docx`, HTML or database-row loader
/// to mislabel its output as ``text``.
///
/// It also keeps decoding total. A closed enum throws on an unrecognised raw value, so a store
/// written by a build (or a Python engine) that knows a format this one does not would fail to
/// read back rather than degrade. The raw strings match Python's `DocumentType`, whose `str`-based
/// enum is likewise open in practice — its `Document` dataclass validates nothing, so its own
/// cloud loaders infer types from file extensions it never enumerates.
public struct RTSRAGDocumentType: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let text = RTSRAGDocumentType(rawValue: "text")
    public static let markdown = RTSRAGDocumentType(rawValue: "markdown")
    public static let pdf = RTSRAGDocumentType(rawValue: "pdf")
    public static let csv = RTSRAGDocumentType(rawValue: "csv")
    public static let json = RTSRAGDocumentType(rawValue: "json")
    public static let jsonLines = RTSRAGDocumentType(rawValue: "jsonl")

    // Coded as a bare string rather than the synthesised `{"rawValue": …}` object, so the wire
    // format is byte-identical to the closed enum this replaced and to Python's values. Written
    // out rather than left to the standard library's `RawRepresentable` defaults, because this
    // shape reaches persisted stores and should not depend on which conformance wins.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
