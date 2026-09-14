//
//  RTSRAGIdentity.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-14.
//

import Crypto
import Foundation

// MARK: - Document identity

public extension RTSRAGDocument {
    /// A UUID v5 derived from `source`, so the same source yields the same id in every process.
    ///
    /// This is what makes an update an update: replacing a document means clearing every entry
    /// carrying its id, which only finds the prior version if the id is reproducible. A random id
    /// per load would silently orphan the old chunks alongside the new ones.
    ///
    /// Uses RFC 4122's URL namespace and the same construction as Python's
    /// `uuid5(NAMESPACE_URL, source)`, so a store written by either engine agrees on ids.
    static func derivedID(for source: String) -> UUID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(RTSRAGDocument.urlNamespaceBytes))
        hasher.update(data: Data(source.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        // Version 5 in the high nibble of byte 6, RFC 4122 variant in the top bits of byte 8.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// RFC 4122 namespace for URLs: `6ba7b811-9dad-11d1-80b4-00c04fd430c8`.
    private static let urlNamespaceBytes: [UInt8] = [
        0x6B, 0xA7, 0xB8, 0x11, 0x9D, 0xAD, 0x11, 0xD1,
        0x80, 0xB4, 0x00, 0xC0, 0x4F, 0xD4, 0x30, 0xC8,
    ]
}

// MARK: - Content hashing

public enum RTSRAGContentHash {
    /// SHA-256 of `content`, hex encoded.
    ///
    /// Answers "has this source changed since it was last ingested?" — deliberately *not* "does
    /// this content already exist somewhere?". Identical content under two different sources
    /// hashes the same but ingests twice, because the skip check pairs this with the source path.
    /// That keeps provenance intact when the same passage legitimately appears in two documents.
    public static func of(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
