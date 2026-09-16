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
            case .resolve, .load, .chunk, .embed:
                return true
            case .store:
                return false
            }
        }

        /// What the phase is waiting on, for the placeholder line.
        var pendingNote: String {
            switch self {
            case .store:
                return "pending — RTSRAGVectorStore (phase 5) not implemented"
            case .resolve, .load, .chunk, .embed:
                return ""
            }
        }
    }

    // MARK: - Embedder

    /// Which embedder the run uses.
    ///
    /// Offered as a choice because the two differ in ways no unit test can show: dimension, speed,
    /// whether anything is billed, and whether the corpus leaves the machine at all.
    enum EmbedderChoice: String, CaseIterable, Identifiable {
        case apple
        case openAI

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .apple:
                return "On-device"
            case .openAI:
                return "OpenAI"
            }
        }

        var note: String {
            switch self {
            case .apple:
                return "NLContextualEmbedding — 512-dim, free, offline, 256-token cap"
            case .openAI:
                return "text-embedding-3-small — 1536-dim, billed per token, needs a key"
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

        /// Which chunker pairs with this format.
        ///
        /// The pairing is the whole reason the library puts the chunker on the ingest call rather
        /// than on the runtime: CSV and JSON loaders already emit one document per record, so the
        /// record *is* the chunk and splitting again would strand a row's columns across two
        /// embeddings. Text and PDF documents are prose and need real boundaries.
        func makeChunker() -> any RTSRAGChunker {
            switch self {
            case .csv, .json:
                return RTSRAGIdentityChunker()
            case .text, .pdf:
                return RTSRAGSentenceChunker()
            }
        }

        var chunkerNote: String {
            switch self {
            case .csv, .json:
                return "identity chunker — the record is already the chunk"
            case .text, .pdf:
                return "sentence chunker — packed to \(RTSRAGLimits.defaultMaxChunkCharacters) characters"
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
    var chunkCount = 0
    var chunkFailureCount = 0
    var embedder: EmbedderChoice = .apple
    var embeddedCount = 0
    var embedFailureCount = 0
    var embeddedTokens = 0
    /// Dimension of the first vector produced, which is the most visible difference between the
    /// two embedders.
    var vectorDimension: Int?
    /// First document of the run, kept so the preview can show what a "document" actually is for
    /// the chosen format.
    var previewDocument: RTSRAGDocument?
    /// That document's chunks, which is where the difference between the two chunkers shows: the
    /// identity chunker returns the document unchanged, the sentence chunker returns slices.
    var previewChunks: [RTSRAGChunk] = []
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

        let chunker = format.makeChunker()
        append(.load, "starting")
        append(.chunk, format.chunkerNote)
        append(.embed, embedder.note)
        guard let embedding = await makeEmbedder() else {
            return
        }
        // Each document is chunked as it arrives rather than after the whole corpus loads, which
        // is what keeps the stream's back-pressure meaningful — nothing is read ahead of what the
        // pipeline has finished with.
        for await element in observed {
            if Task.isCancelled {
                append(.load, "cancelled after \(documentCount) document(s)")
                return
            }
            switch element {
            case .success(let document):
                documentCount += 1
                await chunk(document, with: chunker, embedding: embedding)
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
        append(
            .chunk,
            "produced \(chunkCount) chunk(s) from \(documentCount) document(s), "
                + "\(chunkFailureCount) failure(s)"
        )
        append(
            .embed,
            "embedded \(embeddedCount) of \(chunkCount) chunk(s), \(embedFailureCount) failure(s)"
                + (vectorDimension.map { ", \($0) dimensions" } ?? "")
                + (embeddedTokens > 0 ? ", \(embeddedTokens) tokens billed" : "")
        )
        appendPendingPhases()
    }

    private func chunk(
        _ document: RTSRAGDocument,
        with chunker: any RTSRAGChunker,
        embedding: any RTSRAGEmbedding
    ) async {
        let chunks: [RTSRAGChunk]
        do {
            chunks = try await chunker.chunk(document)
        } catch {
            // A chunker failing one document does not end the run, matching how the loader treats
            // one unreadable file.
            chunkFailureCount += 1
            append(.chunk, "⚠️ \(sourceLabel(document.source)): \(error)")
            return
        }
        chunkCount += chunks.count
        if previewDocument == nil {
            previewDocument = document
            previewChunks = chunks
        }
        await embed(chunks, from: document, with: embedding)
    }

    /// Embeds one document's chunks, which is the pipeline's real unit: a document is embedded
    /// whole before anything about it is committed, so a batch that never succeeds means simply
    /// not committing rather than storing a partial document.
    private func embed(
        _ chunks: [RTSRAGChunk],
        from document: RTSRAGDocument,
        with embedding: any RTSRAGEmbedding
    ) async {
        guard !chunks.isEmpty else {
            return
        }
        for outcome in await embedding.embed(chunks) {
            switch outcome {
            case .embedded(let embedded, let metrics):
                embeddedCount += embedded.count
                embeddedTokens += metrics.inputTokens ?? 0
                if vectorDimension == nil {
                    vectorDimension = embedded.first?.vector.count
                }
            case .failed(let failure):
                embedFailureCount += failure.chunks.count
                append(
                    .embed,
                    "⚠️ \(sourceLabel(document.source)) [\(failure.kind)] "
                        + "\(failure.chunks.count) chunk(s) after \(failure.attempts) attempt(s): "
                        + failure.underlying
                )
            }
        }
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
        chunkCount = 0
        chunkFailureCount = 0
        embeddedCount = 0
        embedFailureCount = 0
        embeddedTokens = 0
        vectorDimension = nil
        previewDocument = nil
        previewChunks = []
    }

    /// Builds the chosen embedder, or reports why it cannot be built.
    ///
    /// Both failure modes are real and worth showing rather than crashing: the on-device model may
    /// not have downloaded its assets, and the OpenAI path needs a key in the Keychain.
    private func makeEmbedder() async -> (any RTSRAGEmbedding)? {
        switch embedder {
        case .apple:
            do {
                let apple = try RTSRAGAppleEmbedding()
                try await apple.prepare()
                return apple
            } catch {
                append(.embed, "❌ \(error)")
                return nil
            }
        case .openAI:
            guard let key = KeychainHelper.readOpenAIKey(), !key.isEmpty else {
                append(.embed, "❌ no OpenAI key in the Keychain")
                return nil
            }
            return RTSRAGOpenAIEmbedding(apiKey: key)
        }
    }
}
