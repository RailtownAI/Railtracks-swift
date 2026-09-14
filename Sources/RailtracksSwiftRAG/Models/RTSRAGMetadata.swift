//
//  RTSRAGMetadata.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Foundation

// MARK: - RTSRAGMetadataValue

/// A JSON-like value, used for the freeform metadata carried alongside documents and chunks.
///
/// Deliberately a local type rather than `RTSValue` from RailtracksSwift: the model layer of this
/// module imports nothing from the agent runtime, so it can be lifted into its own package
/// without untangling a dependency first. The shapes overlap, and that is accepted — the cost of
/// one small enum is lower than the cost of the coupling.
///
/// Only the cases a metadata bag needs: no image case, and no provision for arbitrary nesting
/// depth beyond what filtering can express.
public enum RTSRAGMetadataValue: Sendable, Hashable, Codable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([RTSRAGMetadataValue])
    case object([String: RTSRAGMetadataValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Ordered narrowest first: `Bool` before the numeric cases, because JSON `true` would
        // otherwise decode as an integer on some platforms, and `Int` before `Double` so a whole
        // number survives a round trip as an integer.
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RTSRAGMetadataValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RTSRAGMetadataValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported metadata value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - RTSRAGMetadata

/// Freeform metadata attached to a document or a chunk.
///
/// Flat equality on these keys is what a store's metadata filtering matches against, so the
/// scalar cases are the ones that matter in practice; nested values round-trip but are not
/// filterable.
public typealias RTSRAGMetadata = [String: RTSRAGMetadataValue]
