//
//  RTSRAGCSVLoader.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

/// Loads CSV files, **one document per row**.
///
/// Each row is rendered as labelled pairs, one per line, which is the text that gets embedded:
///
/// ```
/// name,age,city          →     name: Alice
/// Alice,30,NYC                 age: 30
///                              city: NYC
/// ```
///
/// Not the raw `Alice,30,NYC`. The embedding model sees only this string, so including the column
/// names is what makes a row's meaning legible to a similarity search — bare values give the model
/// no reason to connect `30` with age. Columns outside the content set become metadata instead, so
/// they remain filterable without diluting the embedding.
public struct RTSRAGCSVLoader: RTSRAGDocumentLoader {
    static let supportedExtensions: Set<String> = ["csv"]

    private let path: URL
    /// Columns whose values form the content. `nil` uses every column, in header order.
    private let contentColumns: [String]?
    /// Column supplying each row's identity. When `nil`, the row's position is used — which is
    /// only stable while the row order is, so inserting a row rewrites the identity of every row
    /// below it and re-ingests them as new documents.
    private let idColumn: String?
    private let ignoreColumns: Set<String>
    private let contentSeparator: String

    public init(
        path: URL,
        contentColumns: [String]? = nil,
        idColumn: String? = nil,
        ignoreColumns: [String] = [],
        contentSeparator: String = "\n"
    ) {
        self.path = path
        self.contentColumns = contentColumns
        self.idColumn = idColumn
        self.ignoreColumns = Set(ignoreColumns)
        self.contentSeparator = contentSeparator
    }

    public func stream() throws -> RTSRAGDocumentStream {
        let resolved = try RTSRAGFileEnumeration.resolveSources(
            at: path,
            extensions: RTSRAGCSVLoader.supportedExtensions
        )
        let contentColumns = self.contentColumns
        let idColumn = self.idColumn
        let ignoreColumns = self.ignoreColumns
        let separator = self.contentSeparator
        return RTSRAGDocumentStream(sources: resolved) { url in
            try RTSRAGCSVLoader.makeDocuments(
                at: url,
                contentColumns: contentColumns,
                idColumn: idColumn,
                ignoreColumns: ignoreColumns,
                contentSeparator: separator
            )
        }
    }

    private static func makeDocuments(
        at url: URL,
        contentColumns: [String]?,
        idColumn: String?,
        ignoreColumns: Set<String>,
        contentSeparator: String
    ) throws -> [RTSRAGDocument] {
        let text = try RTSRAGFileEnumeration.readText(at: url)
        let rows = RTSRAGCSVParser.parse(text)
        // A file with no header yields nothing rather than failing — an empty CSV is empty input,
        // not a broken one.
        guard let header = rows.first else {
            return []
        }
        // Header validation is per file, so a directory whose files disagree on schema reports
        // only the offending file rather than abandoning the rest.
        let headerSet = Set(header)
        if let contentColumns {
            for column in contentColumns where !headerSet.contains(column) {
                throw RTSRAGError.loadFailed(
                    source: url.path,
                    reason: "content column '\(column)' is not in the header"
                )
            }
        }
        if let idColumn, !headerSet.contains(idColumn) {
            throw RTSRAGError.loadFailed(
                source: url.path,
                reason: "id column '\(idColumn)' is not in the header"
            )
        }

        let effectiveContentColumns = contentColumns ?? header
        let contentColumnSet = Set(effectiveContentColumns)
        var documents: [RTSRAGDocument] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            // Short rows are padded so a ragged file yields empty values rather than dropping
            // columns, which would silently change what gets embedded.
            let padding = Array(repeating: "", count: max(0, header.count - row.count))
            let fields = Dictionary(uniqueKeysWithValues: zip(header, row + padding))
            let content = effectiveContentColumns
                .map { "\($0): \(fields[$0] ?? "")" }
                .joined(separator: contentSeparator)

            var metadata: RTSRAGMetadata = [:]
            for column in header {
                guard !contentColumnSet.contains(column), !ignoreColumns.contains(column) else {
                    continue
                }
                metadata[column] = .string(fields[column] ?? "")
            }
            metadata["row_index"] = .integer(offset)

            let rowID = idColumn.flatMap { fields[$0] } ?? String(offset)
            documents.append(
                RTSRAGDocument(
                    content: content,
                    type: .csv,
                    source: "\(url.path)#\(rowID)",
                    metadata: metadata
                )
            )
        }
        return documents
    }
}

// MARK: - RTSRAGCSVParser

/// A minimal RFC 4180 reader: quoted fields, embedded commas and newlines, and `""` escapes.
///
/// Hand-written because Foundation has no CSV parser and the alternative — splitting on commas —
/// silently corrupts any file containing a quoted field, which is most real-world CSV.
enum RTSRAGCSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pushback: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while true {
            let character: Character
            if let held = pushback {
                character = held
                pushback = nil
            } else if let next = iterator.next() {
                character = next
            } else {
                break
            }

            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")     // an escaped quote
                        } else {
                            inQuotes = false
                            pushback = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
            case ",":
                endField()
            case "\n":
                endRow()
            case "\r":
                break                              // CRLF: the \n does the work
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        // A file ending in a blank line leaves one final row of a single empty field. That is an
        // artifact of the terminator, not a record, so it is dropped here — at end of input, where
        // "final" can actually be known.
        //
        // Dropping it inside `endRow` instead, which is what this did, also silently swallowed
        // *mid-file* blank rows. In a single-column CSV those are legitimately empty values, and
        // losing one did more than lose a document: every row below shifted its `row_index` and,
        // without an `idColumn`, its derived id — so a blank cell quietly re-identified the rest of
        // the file. In a multi-column CSV a blank line now yields an all-empty document instead;
        // that is data the file really contains, and a sanitizer can drop it without renumbering,
        // since ids are already assigned by then.
        if let last = rows.last, last.count == 1, last[0].isEmpty {
            rows.removeLast()
        }
        return rows
    }
}
