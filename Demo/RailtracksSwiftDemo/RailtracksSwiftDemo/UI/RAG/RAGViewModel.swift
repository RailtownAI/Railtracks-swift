//
//  RAGViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-15.
//

import Combine
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
/// Built ahead of the pipeline it drives, one phase at a time, which is why the status log is
/// organised by **phase** rather than by loader. All five now exist, and phase 6's runtime drives
/// them — so this screen no longer orchestrates anything. It builds the pieces, subscribes to
/// ``RTSRAGRetrievalRuntime/eventPublisher`` and calls one method, which is what an app does.
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

        /// The chunk budget this embedder implies, for labelling the UI before a run starts.
        ///
        /// Mirrors what `run` reads off the constructed embedder. Duplicated rather than built
        /// eagerly because constructing the on-device one can fail — a missing revision or
        /// undownloaded assets — and a label should not need a model to exist.
        var inputBudget: Int {
            switch self {
            case .apple:
                return 256 * RTSRAGAppleEmbedding.defaultCharactersPerToken
            case .openAI:
                return RTSRAGLimits.defaultMaxChunkCharacters
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

        /// - Parameter contentKeys: which fields become embedded content. Empty means *not* "no
        ///   content" but the loader's default — for JSON the whole re-serialized object, for CSV
        ///   every column — which is why the UI labels the empty state rather than leaving it blank.
        func makeLoader(path: URL, contentKeys: [String]) -> any RTSRAGDocumentLoader {
            let keys = contentKeys.isEmpty ? nil : contentKeys
            switch self {
            case .text:
                return RTSRAGTextLoader(path: path)
            case .csv:
                return RTSRAGCSVLoader(path: path, contentColumns: keys)
            case .json:
                return RTSRAGJSONLoader(path: path, contentKeys: keys)
            case .pdf:
                return RTSRAGPDFLoader(path: path)
            }
        }

        /// Whether this format has named fields to choose between.
        var hasSelectableKeys: Bool {
            switch self {
            case .csv, .json:
                return true
            case .text, .pdf:
                return false
            }
        }

        /// The chunker that usually suits this format — a starting point, not a rule.
        ///
        /// Record loaders emit one document per row or object, so the record normally *is* the
        /// chunk. "Normally" is doing work there: an event log's `payload` is a record by structure
        /// and a paragraph by length, so the default is wrong for it. Hence a picker rather than a
        /// derivation.
        var defaultChunker: ChunkerChoice {
            switch self {
            case .csv, .json:
                return .identity
            case .text, .pdf:
                return .sentence
            }
        }
    }

    // MARK: - Chunker

    /// How documents become chunks.
    ///
    /// Separate from the format because the right answer depends on the *shape of the values*, not
    /// the file type. A CSV of short cells and a JSONL of LLM transcripts are both record formats
    /// and want opposite chunkers.
    enum ChunkerChoice: String, CaseIterable, Identifiable {
        case identity
        case sentence

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .identity:
                return "Identity"
            case .sentence:
                return "Sentence"
            }
        }

        func note(maxCharacters: Int) -> String {
            switch self {
            case .identity:
                return "identity — one chunk per document; over \(maxCharacters) characters is rejected, not split"
            case .sentence:
                return "sentence — packed to \(maxCharacters) characters on sentence boundaries"
            }
        }

        /// - Parameter maxCharacters: the chosen embedder's input window.
        ///
        ///   Passed to **both**, not just the sentence one — an over-long record has to fail
        ///   somewhere, and failing at chunk time names the right phase and costs no request.
        ///
        ///   This is the pairing the library expects a caller to apply and does not enforce:
        ///   `maxInputCharacters` is published on `RTSRAGEmbedding` for exactly this, and nothing
        ///   reads it until someone does. The demo stands in for the phase 6 runtime here.
        func makeChunker(maxCharacters: Int) -> any RTSRAGChunker {
            switch self {
            case .identity:
                return RTSRAGIdentityChunker(maxCharacters: maxCharacters)
            case .sentence:
                return RTSRAGSentenceChunker(maxCharacters: maxCharacters)
            }
        }
    }

    // MARK: - State

    var format: Format = .text {
        didSet {
            // Follow the format's usual pairing on a switch, but leave a deliberate override in
            // place — otherwise changing format would silently undo the user's choice.
            guard format != oldValue else {
                return
            }
            chunker = format.defaultChunker
        }
    }
    var chunker: ChunkerChoice = Format.text.defaultChunker
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
    /// Field names found in the selected file, offered as toggles.
    var availableKeys: [String] = []
    /// Which of them become embedded content. Everything unselected becomes filterable metadata —
    /// the two are exclusive, so a key cannot be both matched semantically and filtered on.
    var selectedKeys: Set<String> = []
    var embedder: EmbedderChoice = .apple
    var embeddedCount = 0
    var storedCount = 0
    /// The query box, and what it found. Live only once something has been stored.
    var question: String = ""
    var isSearching = false
    var results: [RTSRAGRetrievedEntry] = []
    var searchNote: String?

    /// Built once per run and kept afterwards, so a query can be asked of what the run stored.
    ///
    /// Held alongside the embedder that filled it: a store is only queryable by the embedder that
    /// wrote it, since two models put the same text in different places.
    /// Kept after the run so a question can be asked of what it stored.
    private var runtime: RTSRAGRetrievalRuntime?
    private var subscription: AnyCancellable?
    /// Dimension of the first vector produced, which is the most visible difference between the
    /// two embedders.
    var vectorDimension: Int?

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
            scanKeys(at: url)
        case .failure(let error):
            append(.resolve, "selection failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Key discovery

    /// Reads the first matching file and lists its field names.
    ///
    /// Reads only the first source, not the corpus: the fields are a property of the schema, and a
    /// directory whose files disagree on schema is already reported per file by the loaders.
    func scanKeys(at path: URL) {
        availableKeys = []
        selectedKeys = []
        guard format.hasSelectableKeys else {
            return
        }
        let hasScope = path.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                path.stopAccessingSecurityScopedResource()
            }
        }
        do {
            // `RTSRAGFileEnumeration` is public precisely so a caller can do this without
            // re-implementing the walk, the sort and the extension filter.
            let extensions: Set<String> = format == .csv ? ["csv"] : ["json", "jsonl"]
            guard let first = try RTSRAGFileEnumeration.resolveSources(at: path, extensions: extensions).first else {
                return
            }
            let text = try RTSRAGFileEnumeration.readText(at: first)
            availableKeys = format == .csv ? Self.csvHeader(in: text) : Self.jsonKeys(in: text, url: first)
            append(.resolve, "found \(availableKeys.count) field(s) in \(first.lastPathComponent)")
        } catch {
            append(.resolve, "could not read fields: \(error)")
        }
    }

    /// Header names from the first line.
    ///
    /// Deliberately naive — a header cell containing a quoted comma would split wrongly. The
    /// library's RFC 4180 parser is internal, and this is a convenience for picking fields, not the
    /// parse that produces documents.
    private static func csvHeader(in text: String) -> [String] {
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return []
        }
        return line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// Keys of the first object, whether the file is one object, an array, or JSON Lines.
    private static func jsonKeys(in text: String, url: URL) -> [String] {
        let candidate: String
        if url.pathExtension.lowercased() == "jsonl" {
            guard let line = text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                return []
            }
            candidate = String(line)
        } else {
            candidate = text
        }
        guard let data = candidate.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        if let object = parsed as? [String: Any] {
            return object.keys.sorted()
        }
        if let array = parsed as? [[String: Any]], let first = array.first {
            return first.keys.sorted()
        }
        return []
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
        let contentKeys = availableKeys.filter { selectedKeys.contains($0) }
        if !contentKeys.isEmpty {
            append(.resolve, "content: \(contentKeys.joined(separator: ", ")) — the rest become metadata")
        }
        let loader = format.makeLoader(path: path, contentKeys: contentKeys)
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
            return
        }

        // `mapDocuments` runs once per source with that source's documents, which is what turns a
        // document-level stream into file-level progress. Wrapped around the loader rather than
        // done inside the run, because the runtime drives the loader itself now — and the fact
        // that a loader can be decorated this way is the seam working as intended.
        let progressLoader = ProgressLoader(wrapping: format.makeLoader(path: path, contentKeys: contentKeys)) { [weak self] documents in
            await self?.noteSourceFinished(documents)
        }

        append(.load, "starting")
        append(.embed, embedder.note)
        guard let embedding = await makeEmbedder() else {
            return
        }
        // The chunker is sized from the embedder, not from the format — the two were chosen
        // independently in the UI and would otherwise never meet. On-device caps at 512 characters
        // against the chunker's 1,024 default, which is the mismatch that shows up as
        // `invalidInput` on a page of prose.
        let budget = embedding.maxInputCharacters ?? RTSRAGLimits.defaultMaxChunkCharacters
        let chunking = chunker.makeChunker(maxCharacters: budget)
        append(.chunk, chunker.note(maxCharacters: budget))
        // A fresh store directory per run, so repeated runs over different corpora do not stack up
        // in one index — and so the model guard is not tripped by switching embedder between runs.
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RailtracksSwiftDemoRAGStore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let writing: RTSRAGFileStore
        do {
            writing = try RTSRAGFileStore(directory: storeDirectory)
        } catch {
            append(.store, "❌ \(error)")
            return
        }
        append(.store, "file store at \(storeDirectory.lastPathComponent)")

        // What an app does: build the pieces, subscribe, call one method. The document loop, the
        // chunk/embed calls and the commit rule all live in the runtime.
        let runtime = RTSRAGRetrievalRuntime(embedder: embedding, store: writing)
        self.runtime = runtime
        subscribe(to: runtime)

        do {
            let stats = try await runtime.ingest(loader: progressLoader, chunker: chunking)
            summarise(stats)
            // The full path, last and only on success — it is what another tool needs to open this
            // store, and a path printed before the run could name a store that ended up empty.
            // Selectable in the log, so it can be copied straight into the Résumé Search tab.
            append(.store, "store path: \(storeDirectory.path)")
        } catch {
            // Only an unusable embedder or a store built by a different one reaches here; every
            // per-document problem arrived as an event.
            append(.embed, "❌ \(error)")
            append(.embed, "run stopped — no further documents attempted")
        }
    }

    /// Mirrors the runtime's events into the status log and the counters.
    ///
    /// Subscribing rather than being called back is what lets the UI watch a run it does not drive.
    /// Delivery is asynchronous and order-preserving, so lines arrive in the order the pipeline
    /// produced them without the pipeline ever waiting on SwiftUI.
    private func subscribe(to runtime: RTSRAGRetrievalRuntime) {
        subscription = runtime.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.record(event)
            }
    }

    private func record(_ event: RTSRAGIngestEvent) {
        switch event {
        case .documentLoaded:
            documentCount += 1
        case .documentSkipped(_, let source):
            append(.load, "\(sourceLabel(source)) unchanged — skipped, nothing embedded")
        case .documentChunked(_, let chunks):
            chunkCount += chunks
        case .batchEmbedded(_, let chunks, let metrics):
            embeddedCount += chunks
            if vectorDimension == nil {
                vectorDimension = metrics.dimension
            }
        case .batchFailed(let failure):
            append(
                .embed,
                "⚠️ [\(failure.kind)] \(failure.chunks.count) chunk(s) after "
                    + "\(failure.attempts) attempt(s): \(failure.underlying)"
            )
        case .documentCommitted(_, let stored, let dropped):
            storedCount += stored
            if dropped > 0 {
                append(.store, "committed with \(dropped) chunk(s) dropped — permanently unembeddable")
            }
        case .documentWithheld(_, let reason):
            // Three outcomes needing three different responses, so they must not read the same.
            // Telling someone to retry a document nothing will ever accept is the advice that
            // wasted the most time while this screen was being built.
            switch reason {
            case .transient(let detail):
                append(.store, "⚠️ not committed — \(detail); the previous version stays intact, retry may clear it")
            case .unchunkable(let detail):
                append(.chunk, "⚠️ not committed — \(detail); re-running will fail identically, pick another chunker")
            case .unembeddable(let dropped):
                append(
                    .store,
                    "⚠️ not committed — all \(dropped) chunk(s) permanently rejected; "
                        + "re-running will fail identically, the content cannot be embedded as chunked"
                )
            }
        case .documentEmpty(_, let source):
            // Chunk, not Load: the document arrived intact and it is the *chunker* that produced
            // nothing. Attributing it to Load would point at the wrong phase to go and fix.
            append(.chunk, "\(sourceLabel(source)) produced no chunks — nothing to index, stored version untouched")
        case .loadFailed(let error):
            failureCount += 1
            append(.load, "⚠️ \(error)")
        case .documentSwept(_, let source):
            // An orphan the run's root covered but the run did not see — moved away, or gone.
            append(.store, "\(sourceLabel(source)) no longer at its source — removed")
        }
    }

    private func summarise(_ stats: RTSRAGIngestionStats) {
        append(
            .load,
            "loaded \(stats.documentsLoaded) document(s) from \(sourcesProcessed) file(s), "
                + "\(failureCount) failure(s), \(stats.documentsSkipped) skipped"
        )
        append(.chunk, "produced \(stats.chunksCreated) chunk(s)")
        append(
            .embed,
            "embedded \(stats.chunksEmbedded) chunk(s), \(stats.batchesFailed) batch failure(s)"
                + (vectorDimension.map { ", \($0) dimensions" } ?? "")
                // Tokens and latency are the two halves of what a run cost, and which half exists
                // depends on the path: a metered provider reports tokens, an on-device run reports
                // none and only latency says anything at all.
                + (stats.inputTokens.map { ", \($0) tokens billed" } ?? "")
                + String(format: ", %.1fs in the embedder", stats.embeddingLatency)
        )
        append(
            .store,
            "stored \(stats.chunksStored) chunk(s) across \(stats.documentsCommitted) document(s)"
                + (stats.chunksDropped > 0 ? ", \(stats.chunksDropped) dropped" : "")
                // Withheld documents belong in the totals, not only in the per-event lines: they
                // are precisely what a re-run will pick up, so a reader deciding whether to run
                // again needs the number without scrolling.
                + (stats.documentsWithheld > 0 ? ", \(stats.documentsWithheld) withheld for retry" : "")
                // Kept apart from the line above rather than added to it: one number is an
                // invitation to run again and the others are instructions to change something.
                + (stats.documentsUnchunkable > 0 ? ", \(stats.documentsUnchunkable) unchunkable" : "")
                + (stats.documentsUnembeddable > 0 ? ", \(stats.documentsUnembeddable) unembeddable" : "")
                + (stats.documentsEmpty > 0 ? ", \(stats.documentsEmpty) empty" : "")
                + (stats.chunksStored > 0 ? " — ask a question below" : "")
        )
        // The invariant made visible. A shortfall means a document reached no outcome at all, which
        // is a library bug rather than anything the corpus did — worth saying out loud on the one
        // screen that watches whole runs.
        if stats.documentsAccountedFor != stats.documentsLoaded {
            append(
                .store,
                "⚠️ \(stats.documentsLoaded) document(s) loaded but only "
                    + "\(stats.documentsAccountedFor) accounted for — please report this"
            )
        }
        // One verdict rather than a wall of scrollback. `needsAttention` means "something went
        // wrong", not "a re-run will not fix it" — some of these clear on their own and some never
        // will, so the line reports the numbers and lets the per-document lines above give the
        // advice, each of which already names its own remedy.
        if stats.needsAttention {
            append(
                .store,
                "⚠️ this run needs a look: \(stats.chunksDropped) chunk(s) dropped, "
                    + "\(stats.documentsUnchunkable) document(s) no chunker would take, "
                    + "\(stats.documentsUnembeddable) no embedder would take, "
                    + "\(stats.documentsWithheld) withheld, "
                    + "\(stats.failures.count) failure(s) recorded"
            )
        }
    }


    // MARK: - Retrieval

    /// Embeds the question with the run's own embedder and searches what it stored.
    ///
    /// The same embedder deliberately: a store is only queryable by the model that wrote it, since
    /// two models place the same text in different parts of the space and the scores would look
    /// perfectly reasonable while meaning nothing.
    func search() {
        guard let runtime, !question.isEmpty else {
            return
        }
        isSearching = true
        results = []
        searchNote = nil
        let question = self.question
        Task { [weak self] in
            defer {
                self?.isSearching = false
            }
            do {
                // The runtime embeds the question with the same embedder that filled the store and
                // searches in one call — the store refuses a foreign query vector, so there is
                // nothing for the caller to check.
                let result = try await runtime.retrieve(question, topK: 5)
                self?.results = result.entries
                self?.searchNote = result.entries.isEmpty ? "no matches" : nil
            } catch {
                self?.searchNote = "\(error)"
            }
        }
    }

    var canSearch: Bool {
        runtime != nil && !question.isEmpty && !isSearching && !isRunning
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
        embeddedCount = 0
        storedCount = 0
        results = []
        searchNote = nil
        vectorDimension = nil
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
