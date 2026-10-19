//
//  RAGSpotlightViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-28.
//

import Combine
import CoreSpotlight
import Foundation
import RailtracksSwift
import RailtracksSwiftRAG

/// Ingests PDFs into the app's Spotlight index and searches them back with `CSUserQuery`.
///
/// Phase B of `docs/spotlight-rag.md`: the first run of the Spotlight path inside an app, against
/// the **default** index. Loader and chunker are fixed — `RTSRAGPDFLoader` per page and
/// `RTSRAGSentenceChunker` — because the screen exists to exercise Spotlight, not the loaders.
///
/// Two ways to read it back, side by side: **raw search**, `RTSRAGSpotlightSearcher` with no model
/// in between, so a hit proves the donation itself; and **an agent** (phase C) whose only knowledge
/// is `RTSKnowledgeSearchTool` over the same searcher, on Claude or Apple's on-device model.
@MainActor
@Observable
class RAGSpotlightViewModel {

    /// Which model answers in the agent section.
    enum ModelChoice: String, CaseIterable, Identifiable {
        case claude
        case onDevice

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .claude:
                return "Claude"
            case .onDevice:
                return "On-device"
            }
        }

        /// The on-device model needs FoundationModels; the main demo target deploys below it.
        static var available: [ModelChoice] {
            if #available(macOS 26, iOS 26, *) {
                return allCases
            }
            return [.claude]
        }
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
    var hits: [RTSRAGSpotlightHit] = []
    var searchNote: String?

    var agentQuestion = ""
    var model: ModelChoice = .claude
    var isAsking = false
    var answer: String?
    var agentError: String?
    /// Every passage the tool handed the agent, across all its searches for one question.
    var retrieved: [RTSKnowledgeHit] = []

    /// One feeder, runtime and searcher for the screen's lifetime, all over the default index.
    private let feeder = RTSRAGSpotlightFeeder()
    private let runtime: RTSRAGSpotlightIngestRuntime
    private let searcher: RTSRAGSpotlightSearcher
    private var subscription: AnyCancellable?
    private var runTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Each loaded page's source, so a commit — whose event carries only the id — can be named.
    private var loadedSources: [RTSRAGDocumentID: String] = [:]

    init() {
        runtime = RTSRAGSpotlightIngestRuntime(feeder: feeder)
        searcher = RTSRAGSpotlightSearcher(feeder: feeder)
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

    var canAsk: Bool {
        !agentQuestion.isEmpty && !isRunning && !isAsking
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
                    + "\(stats.documentsWithheld) withheld, \(stats.documentsEmpty) empty, "
                    + "\(stats.documentsSwept) swept"
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
        case .documentLoaded(let id, let source):
            documentCount += 1
            loadedSources[id] = source
        case .documentChunked(_, let chunks):
            chunkCount += chunks
        case .documentCommitted(let id, _, _):
            committedCount += 1
            append("\(Self.label(loadedSources[id])) new or changed — donated to Spotlight")
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
        case .documentSwept(_, let source):
            // An orphan the run's root covered but the run did not see — moved away, or gone.
            append("\(Self.label(source)) no longer at its source — removed from Spotlight")
        case .batchEmbedded, .batchFailed:
            // Embedding events belong to the vector-store path; Spotlight embeds for itself.
            break
        }
    }

    // MARK: - Raw search

    /// Searches this feeder's items directly, cancelling any search still running.
    ///
    /// Kept beside the agent for comparison: this is exactly what the agent's tool sees, before a
    /// model has rephrased anything.
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
        let searcher = self.searcher
        searchTask = Task { [weak self] in
            let found: Result<[RTSRAGSpotlightHit], Error>
            do {
                found = .success(
                    try await searcher.search(question, usesSemanticSearch: usesSemanticSearch)
                )
            } catch {
                found = .failure(error)
            }
            guard !Task.isCancelled else {
                return
            }
            self?.finishSearch(found)
        }
    }

    private func finishSearch(_ found: Result<[RTSRAGSpotlightHit], Error>) {
        isSearching = false
        switch found {
        case .success(let results):
            hits = results
            searchNote = results.isEmpty ? "no matches" : nil
        case .failure(let error):
            searchNote = "❌ \(error)"
        }
    }

    // MARK: - Agent

    /// Answers `agentQuestion` with an agent whose only knowledge is a Spotlight-backed
    /// `RTSKnowledgeSearchTool`.
    ///
    /// The same tool the Résumé Search tab builds over a vector store — only the source behind it
    /// differs, adapted with `RTSClosureKnowledgeSource`.
    func ask() {
        guard canAsk else {
            return
        }
        let gateway: RTSLLMGateway
        let provider: RTSLLMProvider
        switch model {
        case .claude:
            guard let apiKey = KeychainHelper.readAnthropicKey(), !apiKey.isEmpty else {
                agentError = "no Anthropic key in the Keychain — add one on the main screen"
                return
            }
            gateway = RTSLLMGateway(apiKeys: [.anthropic: apiKey])
            provider = .anthropic(modelIDString: RTSAnthropicModelID.claudeSonnet46.modelIDString)
        case .onDevice:
            gateway = RTSLLMGateway(apiKeys: [:])
            provider = .appleAI
        }
        isAsking = true
        answer = nil
        agentError = nil
        retrieved = []
        let question = agentQuestion
        let agent = RTSAgent(
            llmProvider: provider,
            name: "Document Researcher",
            tools: [makeSearchTool()],
            systemMessage: Self.systemMessage
        )
        Task { [weak self] in
            defer {
                self?.isAsking = false
            }
            do {
                let flow = RTSFlow(title: "Spotlight RAG")
                let reply = try await flow.run(agent: agent, prompt: question, gateway: gateway)
                self?.answer = reply
            } catch {
                self?.agentError = "\(error)"
            }
        }
    }

    /// The knowledge tool, over Spotlight.
    ///
    /// The description carries what semantic search does not: matching is by keyword, so the
    /// model is told to search with the documents' own vocabulary and to retry before giving up.
    private func makeSearchTool() -> RTSKnowledgeSearchTool {
        RTSKnowledgeSearchTool(
            toolName: "SearchDocuments",
            toolDescription: """
            Search the user's documents for passages. Matching is by keyword, not meaning: search \
            with distinctive words likely to appear in the text itself (skills, product names, \
            job titles, qualifications). If a search returns nothing, try synonyms or narrower \
            terms before concluding the documents do not cover it. Each passage comes with the \
            file and page it came from.
            """,
            source: makeSource(),
            // No threshold: Spotlight exposes no score, so the one the source derives from rank
            // would filter on nothing real.
            minimumScore: nil
        )
    }

    /// Adapts Spotlight hits to the knowledge tool, recording what the agent was handed.
    private func makeSource() -> RTSClosureKnowledgeSource {
        let searcher = self.searcher
        return RTSClosureKnowledgeSource { [weak self] query in
            let found = try await searcher.search(query.text, limit: query.topK)
            let hits = found.map { hit -> RTSKnowledgeHit in
                var metadata: [String: RTSValue] = [:]
                if let chunkIndex = hit.chunkIndex {
                    metadata["chunk"] = .number(Double(chunkIndex))
                }
                return RTSKnowledgeHit(
                    content: hit.text,
                    source: hit.source ?? hit.title,
                    // Rank-derived: `CSUserQuery` returns order, not relevance.
                    score: 1 / Double(hit.rank + 1),
                    metadata: metadata
                )
            }
            await self?.recordRetrieved(query: query.text, hits: hits)
            return hits
        }
    }

    private func recordRetrieved(query: String, hits: [RTSKnowledgeHit]) {
        retrieved.append(contentsOf: hits)
        append("agent searched \"\(query)\" → \(hits.count) passage(s)")
    }

    private static let systemMessage = """
    You answer questions using only the user's documents, reached through your search tool.

    Always search before answering — never answer from prior knowledge. The search matches \
    keywords, so if it returns nothing, search again with different words before deciding the \
    documents do not cover the question. Cite the file and page for every claim. If nothing is \
    found after a few attempts, say plainly that the documents do not cover it.
    """

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
        loadedSources = [:]
    }

    /// `"<path>/file.pdf#page-N"` → `"file.pdf#page-N"`, for the log.
    private static func label(_ source: String?) -> String {
        guard let source else {
            return "(no source)"
        }
        return (source as NSString).lastPathComponent
    }
}
