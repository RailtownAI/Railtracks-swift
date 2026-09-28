//
//  RAGSpotlightViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-28.
//

import Combine
import CoreSpotlight
import Foundation
import RailtracksSwiftRAG

/// Ingests PDFs into the app's Spotlight index and searches them back with `CSUserQuery`.
///
/// Phase B of `docs/spotlight-rag.md`: the first run of the Spotlight path inside an app, against
/// the **default** index. Loader and chunker are fixed — `RTSRAGPDFLoader` per page and
/// `RTSRAGSentenceChunker` — because the screen exists to exercise Spotlight, not the loaders.
///
/// Search is `CSUserQuery` rather than `SpotlightSearchTool`: no model sits between the index and
/// the results, so a hit proves the donation itself.
@MainActor
@Observable
class RAGSpotlightViewModel {

    /// One search hit, flattened from the `CSSearchableItem` it wraps.
    struct Hit: Identifiable {
        /// The item's `"<documentID>#<index>"` identifier.
        let id: String
        /// Arrival order. `CSUserQuery.Item` carries no score, so ranked order is all there is.
        let rank: Int
        let title: String
        let chunkIndex: Int?
        let text: String
        let contentURL: URL?
    }

    var selectedPath: URL?
    var isShowingFileImporter = false
    var isRunning = false
    var statusLog = ""
    var documentCount = 0
    var chunkCount = 0
    var committedCount = 0
    var skippedCount = 0
    var withheldCount = 0

    var question = ""
    /// Off means lexical only, so the two modes can be compared on the same question.
    var usesSemanticSearch = true
    var isSearching = false
    var hits: [Hit] = []
    var searchNote: String?

    /// One feeder and runtime for the screen's lifetime, both over the default index.
    private let feeder = RTSRAGSpotlightFeeder()
    private let runtime: RTSRAGSpotlightIngestRuntime
    private var subscription: AnyCancellable?
    private var runTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init() {
        runtime = RTSRAGSpotlightIngestRuntime(feeder: feeder)
        subscription = runtime.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.record(event)
            }
    }

    var canStart: Bool {
        selectedPath != nil && !isRunning
    }

    var canSearch: Bool {
        !question.isEmpty && !isRunning
    }

    var progressText: String {
        "\(documentCount) page(s) · \(chunkCount) chunk(s) · \(committedCount) donated"
            + " · \(skippedCount) skipped · \(withheldCount) withheld"
    }

    /// Warms Spotlight's query machinery, as `CSUserQuery` recommends doing before first use.
    func prepare() {
        CSUserQuery.prepare()
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
            append("selected \(url.path)")
        case .failure(let error):
            append("selection failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Ingest

    func start() {
        guard let selectedPath else {
            return
        }
        resetCounters()
        isRunning = true
        runTask = Task { [weak self] in
            await self?.run(path: selectedPath)
        }
    }

    func cancel() {
        guard isRunning else {
            return
        }
        runTask?.cancel()
        append("cancel requested, stopping at the next page")
    }

    private func run(path: URL) async {
        defer {
            isRunning = false
            runTask = nil
        }
        // A picked URL only grants access while its security scope is held. For a folder, the
        // scope covers the files inside it.
        let hasScope = path.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                path.stopAccessingSecurityScopedResource()
            }
        }

        append("PDF loader (per page) · sentence chunker · default Spotlight index")
        do {
            let stats = try await runtime.ingest(
                loader: RTSRAGPDFLoader(path: path),
                chunker: RTSRAGSentenceChunker()
            )
            append(
                "done: \(stats.documentsLoaded) page(s), \(stats.chunksCreated) chunk(s), "
                    + "\(stats.documentsCommitted) donated, \(stats.documentsSkipped) skipped, "
                    + "\(stats.documentsWithheld) withheld, \(stats.documentsEmpty) empty"
            )
            if stats.documentsSkipped == stats.documentsLoaded, stats.documentsLoaded > 0 {
                append("every page unchanged — the staleness check held on the default index")
            }
        } catch {
            append("❌ \(error)")
        }
    }

    /// Mirrors the runtime's events into the log and the counters.
    private func record(_ event: RTSRAGIngestEvent) {
        switch event {
        case .documentLoaded:
            documentCount += 1
        case .documentChunked(_, let chunks):
            chunkCount += chunks
        case .documentCommitted:
            committedCount += 1
        case .documentSkipped(_, let source):
            skippedCount += 1
            append("\(Self.label(source)) unchanged — skipped")
        case .documentWithheld(_, let reason):
            withheldCount += 1
            append("⚠️ withheld: \(reason)")
        case .documentEmpty(_, let source):
            append("\(Self.label(source)) produced no chunks")
        case .loadFailed(let error):
            append("⚠️ \(error)")
        case .batchEmbedded, .batchFailed:
            // Embedding events belong to the vector-store path; Spotlight embeds for itself.
            break
        }
    }

    // MARK: - Search

    /// Searches this feeder's items with `CSUserQuery`, cancelling any search still running.
    func search() {
        guard canSearch else {
            return
        }
        searchTask?.cancel()
        hits = []
        searchNote = nil
        isSearching = true
        let question = self.question
        let usesSemanticSearch = self.usesSemanticSearch
        let filter = feeder.searchFilter
        searchTask = Task { [weak self] in
            let found = await Self.run(
                question: question,
                usesSemanticSearch: usesSemanticSearch,
                filter: filter
            )
            guard !Task.isCancelled else {
                return
            }
            self?.finishSearch(found)
        }
    }

    /// Built where the query runs, so no non-`Sendable` Core Spotlight object crosses actors.
    private nonisolated static func makeQueryContext(
        usesSemanticSearch: Bool,
        filter: String
    ) -> CSUserQueryContext {
        let context = CSUserQueryContext()
        context.enableRankedResults = true
        context.maxResultCount = 10
        context.disableSemanticSearch = !usesSemanticSearch
        // Only this feeder's items, not anything else the app donates.
        context.filterQueries = [filter]
        // Without these a hit is little more than its identifier; with them it carries its passage
        // and where it came from.
        context.fetchAttributes = [
            "title",
            "textContent",
            "containerTitle",
            "containerOrder",
            "contentURL",
        ]
        return context
    }

    private func finishSearch(_ found: Result<[Hit], Error>) {
        isSearching = false
        switch found {
        case .success(let results):
            hits = results
            searchNote = results.isEmpty ? "no matches" : nil
        case .failure(let error):
            searchNote = "❌ \(error)"
        }
    }

    /// Runs one query to completion. The query is started by reading `responses` and cancelled when
    /// the surrounding task is.
    private nonisolated static func run(
        question: String,
        usesSemanticSearch: Bool,
        filter: String
    ) async -> Result<[Hit], Error> {
        let context = makeQueryContext(usesSemanticSearch: usesSemanticSearch, filter: filter)
        let query = CSUserQuery(userQueryString: question, userQueryContext: context)
        return await withTaskCancellationHandler {
            do {
                var results: [Hit] = []
                for try await response in query.responses {
                    guard case .item(let item) = response else {
                        continue
                    }
                    results.append(makeHit(item.item, rank: results.count))
                }
                return .success(results)
            } catch {
                return .failure(error)
            }
        } onCancel: {
            query.cancel()
        }
    }

    private nonisolated static func makeHit(_ item: CSSearchableItem, rank: Int) -> Hit {
        let attributes = item.attributeSet
        return Hit(
            id: item.uniqueIdentifier,
            rank: rank,
            title: attributes.containerTitle ?? attributes.title ?? "(untitled)",
            chunkIndex: attributes.containerOrder?.intValue,
            text: attributes.textContent ?? "",
            contentURL: attributes.contentURL
        )
    }

    // MARK: - Maintenance

    /// Removes everything this feeder donated, and nothing else the app did.
    func clearSpotlight() {
        Task { [weak self] in
            do {
                try await self?.runtime.deleteAll()
                self?.hits = []
                self?.append("cleared this feeder's namespace from Spotlight")
            } catch {
                self?.append("❌ clear failed: \(error)")
            }
        }
    }

    // MARK: - Log

    func clearLog() {
        statusLog = ""
    }

    private func append(_ message: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        statusLog += "\(stamp)  \(message)\n"
    }

    private func resetCounters() {
        documentCount = 0
        chunkCount = 0
        committedCount = 0
        skippedCount = 0
        withheldCount = 0
    }

    /// `"<path>/file.pdf#page-N"` → `"file.pdf#page-N"`, for the log.
    private static func label(_ source: String?) -> String {
        guard let source else {
            return "(no source)"
        }
        return (source as NSString).lastPathComponent
    }
}
