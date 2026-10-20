//
//  RTSRAGTextLoader.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

/// Loads plain text and Markdown, from a single file or recursively from a directory.
///
/// One document per file, with `source` set to the file's path — so re-ingesting an edited file
/// replaces it rather than adding a second copy.
public struct RTSRAGTextLoader: RTSRAGDocumentLoader {
    static let supportedExtensions: Set<String> = ["txt", "md"]

    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func stream() throws -> RTSRAGDocumentStream {
        // Resolution happens here rather than in `init`, so a loader is cheap to construct and a
        // bad path is reported when the caller actually asks to read.
        let resolved = try RTSRAGFileEnumeration.resolveSources(
            at: path,
            extensions: RTSRAGTextLoader.supportedExtensions
        )
        return RTSRAGDocumentStream(sources: resolved, root: path) { url in
            [try RTSRAGTextLoader.makeDocument(at: url)]
        }
    }

    private static func makeDocument(at url: URL) throws -> RTSRAGDocument {
        let content = try RTSRAGFileEnumeration.readText(at: url)
        let fileExtension = url.pathExtension.lowercased()
        return RTSRAGDocument(
            content: content,
            type: fileExtension == "md" ? .markdown : .text,
            source: url.path,
            metadata: ["file_type": .string(fileExtension)]
        )
    }
}
