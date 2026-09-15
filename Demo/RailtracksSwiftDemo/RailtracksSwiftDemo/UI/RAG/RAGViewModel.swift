//
//  RAGViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-15.
//

import Foundation
import RailtracksSwiftRAG
import UniformTypeIdentifiers
import Logging
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A harness for the RAG ingest pipeline: pick a format, pick a file or folder, and watch each
/// phase report as it runs.
///
/// Built ahead of the pipeline it drives. Only **Load** exists today (`RailtracksSwiftRAG` phase 2);
/// Chunk, Embed and Store are listed as pending so each one fills in its own lines here as it
/// lands, rather than needing this screen rebuilt.
@MainActor
@Observable
class RAGViewModel {

    // MARK: - Phase

    /// The stages of an ingest, in order. Every status line is attributed to one.
    enum Phase: String, CaseIterable, Identifiable {
        case resolve
        case load
        case chunk
        case embed
        case store

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .resolve:
                return "Resolve"
            case .load:
                return "Load"
            case .chunk:
                return "Chunk"
            case .embed:
                return "Embed"
            case .store:
                return "Store"
            }
        }

        /// Whether the library implements this phase yet.
        var isImplemented: Bool {
            switch self {
            case .resolve, .load:
                return true
            case .chunk, .embed, .store:
                return false
            }
        }

        /// What the phase is waiting on, for the placeholder line.
        var pendingNote: String {
            switch self {
            case .chunk:
                return "pending — RTSRAGChunker (phase 3) not implemented"
            case .embed:
                return "pending — RTSRAGEmbedding (phase 4) not implemented"
            case .store:
                return "pending — RTSRAGVectorStore (phase 5) not implemented"
            case .resolve, .load:
                return ""
            }
        }
    }

    // MARK: - Format

    /// Which loader `Start` constructs.
    ///
    /// A picker rather than inference from the extension, because the library has no format
    /// dispatcher by design: a `.csv` is reasonably ingested as one document per row, as a single
    /// text blob, or as selected columns with the rest as metadata, and the file cannot say which
    /// is wanted. Picking here mirrors how an app is expected to choose.
    enum Format: String, CaseIterable, Identifiable {
        case text
        case csv
        case json
        case pdf

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .text:
                return "Text"
            case .csv:
                return "CSV"
            case .json:
                return "JSON"
            case .pdf:
                return "PDF"
            }
        }

        /// What one file of this format produces, which is the interesting difference between them.
        var granularityNote: String {
            switch self {
            case .text:
                return ".txt/.md — one document per file"
            case .csv:
                return ".csv — one document per row"
            case .json:
                return ".json/.jsonl — one document per object"
            case .pdf:
                return ".pdf — one document per page"
            }
        }

        /// Types the importer will offer. `.folder` is always included so the same button picks a
        /// single file or a directory to walk.
        var contentTypes: [UTType] {
            switch self {
            case .text:
                return [.folder, .plainText, UTType(filenameExtension: "md") ?? .plainText]
            case .csv:
                return [.folder, .commaSeparatedText]
            case .json:
                return [.folder, .json, UTType(filenameExtension: "jsonl") ?? .json]
            case .pdf:
                return [.folder, .pdf]
            }
        }

        func makeLoader(path: URL) -> any RTSRAGDocumentLoader {
            switch self {
            case .text:
                return RTSRAGTextLoader(path: path)
            case .csv:
                return RTSRAGCSVLoader(path: path)
            case .json:
                return RTSRAGJSONLoader(path: path)
            case .pdf:
                return RTSRAGPDFLoader(path: path)
            }
        }
    }

    // MARK: - State

    var format: Format = .text
    var selectedPath: URL?
    var isShowingFileImporter = false
    var isRunning = false
    var statusLog: String = ""
    /// Sources finished so far, and the total resolved up front — the "file N of M" pair.
    var sourcesProcessed = 0
    var sourceTotal = 0
    var documentCount = 0
    var failureCount = 0
    /// First document of the run, kept so the preview can show what a "document" actually is for
    /// the chosen format.
    var previewDocument: RTSRAGDocument?
    var isShowingPreview = false

    private var runTask: Task<Void, Never>?

    var canStart: Bool {
        selectedPath != nil && !isRunning
    }

    // MARK: - Selection

    func selectPath() {
        isShowingFileImporter = true
    }

    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            selectedPath = url
            resetRunState()
            statusLog = ""
            append(.resolve, "selected \(url.path)")
        case .failure(let error):
            append(.resolve, "selection failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Run

    func start() {
        guard let selectedPath else {
            return
        }
        let format = self.format
        resetRunState()
        statusLog = ""
        isRunning = true
        runTask = Task { [weak self] in
            await self?.run(format: format, path: selectedPath)
        }
    }

    func cancel() {
        guard isRunning else {
            return
        }
        runTask?.cancel()
        // The stream is lazy and nothing inside a loader polls for cancellation, so this takes
        // effect when the consumer next comes around — a document boundary, not mid-file.
        append(.load, "cancel requested, stopping at the next document")
    }

    private func run(format: Format, path: URL) async {
        defer {
            isRunning = false
            runTask = nil
        }

        // A picked URL only grants access while its security scope is held — without this the
        // sandbox denies the read and every file arrives as a `.failure`.
        let hasScope = path.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                path.stopAccessingSecurityScopedResource()
            }
        }

        append(.resolve, "\(format.title) loader over \(path.lastPathComponent)")
        let loader = format.makeLoader(path: path)
        let stream: RTSRAGDocumentStream
        do {
            // `stream()` throws only for failures that make the whole run meaningless — a missing
            // path, or a single file whose extension the loader does not handle. Anything found
            // while reading arrives as a `.failure` element instead.
            stream = try loader.stream()
        } catch {
            append(.resolve, "❌ \(error)")
            return
        }
        sourceTotal = stream.sourceCount
        append(.resolve, "\(stream.sourceCount) file(s) matched")
        guard stream.sourceCount > 0 else {
            append(.load, "nothing to load")
            appendPendingPhases()
            return
        }

        // `mapDocuments` runs once per source with that source's documents, which is what turns
        // a document-level stream into file-level progress without parsing paths.
        let observed = stream.mapDocuments { [weak self] documents in
            await self?.noteSourceFinished(documents)
            return documents
        }

        append(.load, "starting")
        for await element in observed {
            if Task.isCancelled {
                append(.load, "cancelled after \(documentCount) document(s)")
                return
            }
            switch element {
            case .success(let document):
                documentCount += 1
                if previewDocument == nil {
                    previewDocument = document
                }
            case .failure(let error):
                // One unreadable file does not end the run — that is the library's departure from
                // the Python engine, and this is where it shows.
                failureCount += 1
                append(.load, "⚠️ \(error)")
            }
        }
        append(
            .load,
            "loaded \(documentCount) document(s) from \(sourcesProcessed) file(s), "
                + "\(failureCount) failure(s)"
        )
        appendPendingPhases()
    }

    private func noteSourceFinished(_ documents: [RTSRAGDocument]) {
        sourcesProcessed += 1
        let label = documents.first.map { sourceLabel($0.source) } ?? "(empty)"
        // A source that produced nothing is worth a line of its own: it emits no elements, so
        // without this it would be indistinguishable from a file that was never opened.
        append(.load, "[\(sourcesProcessed)/\(sourceTotal)] \(label) → \(documents.count) document(s)")
    }

    /// Display-only file name for a document source. CSV and PDF append `#row` / `#page-N`, which
    /// is trimmed here; a path legitimately containing `#` would render oddly, which costs nothing
    /// since this is a label.
    private func sourceLabel(_ source: String?) -> String {
        guard let source else {
            return "(no source)"
        }
        let filePart = source.split(separator: "#", maxSplits: 1).first.map(String.init) ?? source
        return URL(fileURLWithPath: filePart).lastPathComponent
    }

    private func appendPendingPhases() {
        for phase in Phase.allCases where !phase.isImplemented {
            append(phase, phase.pendingNote)
        }
    }

    // MARK: - Log

    func clearLog() {
        statusLog = ""
    }

    func copyLog() {
        #if canImport(UIKit)
        UIPasteboard.general.string = statusLog
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statusLog, forType: .string)
        #endif
    }

    private func append(_ phase: Phase, _ message: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        statusLog += "\(stamp)  \(phase.title.padding(toLength: 8, withPad: " ", startingAt: 0))\(message)\n"
        Log.debug("📚 \(phase.title): \(message)")
    }

    private func resetRunState() {
        sourcesProcessed = 0
        sourceTotal = 0
        documentCount = 0
        failureCount = 0
        previewDocument = nil
    }
}
