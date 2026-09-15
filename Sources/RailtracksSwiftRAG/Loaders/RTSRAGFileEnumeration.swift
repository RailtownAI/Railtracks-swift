//
//  RTSRAGFileEnumeration.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation

/// Resolves a path into the ordered list of files a loader should read.
enum RTSRAGFileEnumeration {

    /// Every file under `path` with one of `extensions`, sorted — or `path` itself when it is a
    /// file rather than a directory.
    ///
    /// Directory traversal is recursive and the result is **sorted explicitly**, because neither
    /// `FileManager.enumerator` nor Python's `rglob` guarantees an order and the ingest order is
    /// observable — it decides which documents reach the store first.
    ///
    /// - Throws: `RTSRAGError.loadFailed` when the path does not exist, or when a single file has
    ///   an unsupported extension. Both are precondition failures: they mean the loader was
    ///   pointed at the wrong thing, so they end the stream rather than becoming a `.failure`
    ///   element. Python validates these in a different order per loader — extension first in
    ///   `TextLoader`, existence first in `CSVLoader` — so the same mistake reports differently.
    ///   Here it is always existence first, which is the more useful message.
    static func resolveSources(
        at path: URL,
        extensions: Set<String>
    ) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw RTSRAGError.loadFailed(source: path.path, reason: "path does not exist")
        }
        guard isDirectory.boolValue else {
            let fileExtension = path.pathExtension.lowercased()
            guard extensions.contains(fileExtension) else {
                let supported = extensions.sorted().joined(separator: ", ")
                throw RTSRAGError.loadFailed(
                    source: path.path,
                    reason: "unsupported extension '\(fileExtension)', expected: \(supported)"
                )
            }
            return [path]
        }
        return try enumerateDirectory(at: path, extensions: extensions, fileManager: fileManager)
    }

    private static func enumerateDirectory(
        at directory: URL,
        extensions: Set<String>,
        fileManager: FileManager
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw RTSRAGError.loadFailed(
                source: directory.path,
                reason: "could not enumerate directory"
            )
        }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Reads a text file.
    ///
    /// - Note: no byte-order-mark handling, and that is correct rather than an omission. Python
    ///   defaults its loaders to `utf-8-sig` because plain `utf-8` would leave a `U+FEFF` at the
    ///   start of the content — which breaks CSV header matching and corrupts the content hash.
    ///   Foundation strips it already, verified against `String(contentsOf:encoding:)`,
    ///   `String(data:encoding:)` and `JSONSerialization`. A test pins the behaviour, since BOMs
    ///   are common in Excel-exported CSV.
    static func readText(at url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw RTSRAGError.loadFailed(source: url.path, reason: "\(error)")
        }
    }
}
