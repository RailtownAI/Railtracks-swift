//
//  RTSRAGJSONLoader.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

/// Loads `.json` and `.jsonl` files, **one document per object**.
///
/// A `.json` file holds either a single object or an array of them; a `.jsonl` file holds one
/// object per line, with blank lines skipped.
public struct RTSRAGJSONLoader: RTSRAGDocumentLoader {
    static let supportedExtensions: Set<String> = ["json", "jsonl"]

    private let path: URL
    /// Keys whose values form the content. `nil` — the default — makes the re-serialized object
    /// the content, which keeps every field searchable without naming them.
    private let contentKeys: [String]?
    private let idKey: String?
    private let ignoreKeys: Set<String>
    private let contentSeparator: String

    public init(
        path: URL,
        contentKeys: [String]? = nil,
        idKey: String? = nil,
        ignoreKeys: [String] = [],
        contentSeparator: String = "\n"
    ) {
        self.path = path
        self.contentKeys = contentKeys
        self.idKey = idKey
        self.ignoreKeys = Set(ignoreKeys)
        self.contentSeparator = contentSeparator
    }

    public func stream() throws -> RTSRAGDocumentStream {
        let resolved = try RTSRAGFileEnumeration.resolveSources(
            at: path,
            extensions: RTSRAGJSONLoader.supportedExtensions
        )
        let contentKeys = self.contentKeys
        let idKey = self.idKey
        let ignoreKeys = self.ignoreKeys
        let separator = self.contentSeparator
        return RTSRAGDocumentStream(sources: resolved) { url in
            try RTSRAGJSONLoader.makeDocuments(
                at: url,
                contentKeys: contentKeys,
                idKey: idKey,
                ignoreKeys: ignoreKeys,
                contentSeparator: separator
            )
        }
    }

    private static func makeDocuments(
        at url: URL,
        contentKeys: [String]?,
        idKey: String?,
        ignoreKeys: Set<String>,
        contentSeparator: String
    ) throws -> [RTSRAGDocument] {
        let isLines = url.pathExtension.lowercased() == "jsonl"
        let objects = isLines
            ? try parseLines(at: url)
            : try parseDocument(at: url)
        let type: RTSRAGDocumentType = isLines ? .jsonLines : .json

        return try objects.enumerated().map { index, object in
            try makeDocument(
                from: object,
                index: index,
                url: url,
                type: type,
                contentKeys: contentKeys,
                idKey: idKey,
                ignoreKeys: ignoreKeys,
                contentSeparator: contentSeparator
            )
        }
    }

    private static func parseDocument(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RTSRAGError.loadFailed(source: url.path, reason: "invalid JSON: \(error)")
        }
        if let object = parsed as? [String: Any] {
            return [object]
        }
        if let array = parsed as? [Any] {
            guard let objects = array as? [[String: Any]] else {
                throw RTSRAGError.loadFailed(
                    source: url.path,
                    reason: "JSON array must contain only objects"
                )
            }
            return objects
        }
        throw RTSRAGError.loadFailed(
            source: url.path,
            reason: "JSON file must contain an object or an array of objects"
        )
    }

    private static func parseLines(at url: URL) throws -> [[String: Any]] {
        let text = try RTSRAGFileEnumeration.readText(at: url)
        var objects: [[String: Any]] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineNumber, line) in lines.enumerated() {
            // `.whitespacesAndNewlines`, not `.whitespaces` — the latter is space and tab only, so
            // a stray carriage return would survive and be parsed as if it were a JSON object.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Blank lines are skipped, and the object index counts *objects* rather than lines —
            // so a blank line in the middle does not shift every subsequent identity.
            guard !trimmed.isEmpty else {
                continue
            }
            let parsed = trimmed.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            guard let object = parsed as? [String: Any] else {
                throw RTSRAGError.loadFailed(
                    source: url.path,
                    reason: "line \(lineNumber + 1) is not a JSON object"
                )
            }
            objects.append(object)
        }
        return objects
    }

    private static func makeDocument(
        from object: [String: Any],
        index: Int,
        url: URL,
        type: RTSRAGDocumentType,
        contentKeys: [String]?,
        idKey: String?,
        ignoreKeys: Set<String>,
        contentSeparator: String
    ) throws -> RTSRAGDocument {
        var metadata: RTSRAGMetadata = [:]
        let content: String

        if let contentKeys {
            for key in contentKeys where object[key] == nil {
                throw RTSRAGError.loadFailed(
                    source: url.path,
                    reason: "object \(index) has no key '\(key)'"
                )
            }
            content = contentKeys
                .map { "\($0): \(describe(object[$0]))" }
                .joined(separator: contentSeparator)
            for (key, value) in object {
                guard !contentKeys.contains(key), !ignoreKeys.contains(key) else {
                    continue
                }
                metadata[key] = .string(describe(value))
            }
        } else {
            // The whole object becomes the content. Note the re-serialization does not preserve
            // the source file's key order, where Python's `json.dumps` does — so the two engines
            // can produce different content hashes for the same file. A cross-engine re-ingest
            // therefore re-ingests rather than skipping: a degradation, not a corruption.
            let kept = object.filter { !ignoreKeys.contains($0.key) }
            let data = try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
            content = String(data: data, encoding: .utf8) ?? ""
        }
        metadata["index"] = .integer(index)

        let objectID = idKey.map { describe(object[$0]) } ?? String(index)
        return RTSRAGDocument(
            content: content,
            type: type,
            source: "\(url.path)#\(objectID)",
            metadata: metadata
        )
    }

    /// Renders a JSON value for use in content or metadata, without the `Optional(…)` wrapper a
    /// plain interpolation would produce.
    ///
    /// Nested objects and arrays are re-serialized as JSON with **sorted keys**, not interpolated.
    /// Interpolating one yields `NSDictionary`'s plist-style description — `{ "a" = 1; }` — whose
    /// key order is unspecified, so the same record would hash differently between runs and every
    /// re-ingest would look like a change. The whole-object path already sorts for that reason;
    /// this makes the per-key path agree.
    private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else {
            return ""
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\(value)"
    }
}
