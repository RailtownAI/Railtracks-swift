//
//  ResumeSearchViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-23.
//

import Foundation
import RailtracksSwift
import RailtracksSwiftRAG
import Logging

/// An agent that answers hiring questions from a corpus of résumés, using
/// ``RTSKnowledgeSearchTool`` over a vector store built earlier by the RAG tab.
///
/// **This is the only place the RAG → knowledge-tool mapping is compiled.** `RailtracksSwift`
/// deliberately does not depend on `RailtracksSwiftRAG`, so no test target can see both modules and
/// the mapping in `docs/knowledge-tool.md` cannot be type-checked there. The demo imports both.
///
/// Self-contained on purpose: it opens a store directory the user picks and owns everything from
/// there, so nothing here is coupled to the RAG tab's state.
@MainActor
@Observable
class ResumeSearchViewModel {

    // MARK: - Embedder

    /// Which embedder answers the query — and it must be the one that *wrote* the store, since two
    /// models place the same text in different parts of the space.
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

        /// The prefix `RTSRAGEmbedding.modelIdentifier` starts with for this choice.
        ///
        /// A store records the model that wrote it on every entry, so the right embedder is
        /// *discoverable* rather than something the user has to remember.
        var identifierPrefix: String {
            switch self {
            case .apple:
                return "nl-contextual/"
            case .openAI:
                return "openai/"
            }
        }
    }

    // MARK: - State

    var isShowingFolderPicker = false
    /// Stores found under the RAG tab's own output root, offered as one-click buttons.
    var recentStores: [URL] = []
    var selectedStore: URL?
    /// What the store says about itself once opened: entry count and the model that wrote it.
    var storeSummary: String?
    /// Why the selected folder cannot be used, when it cannot.
    var storeProblem: String?
    var embedder: EmbedderChoice = .apple

    var question: String = ""
    /// Feeds ``RTSKnowledgeSearchTool``'s `minimumScore`. Zero keeps everything the store returns,
    /// which is what a store does on its own — see the caption in the view.
    var relevanceThreshold: Double = 0
    var isRunning = false
    var answer: String?
    var errorText: String?
    /// What the tool actually handed the agent, shown beside the answer so a bad retrieval is
    /// visible rather than inferred from a bad answer.
    var retrieved: [RTSKnowledgeHit] = []

    private var store: RTSRAGFileStore?
    /// Held for as long as the picked folder is in use — a security-scoped URL stops being readable
    /// the moment this is released, and the store replays its log at construction.
    private var scopedURL: URL?

    var canAsk: Bool {
        store != nil && !question.isEmpty && !isRunning
    }

    // MARK: - Store selection

    /// The RAG tab's output root. A path constant, not a code dependency — the tab is otherwise
    /// self-contained, and the folder picker reaches anywhere.
    private static let ragStoreRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("RailtracksSwiftDemoRAGStore", isDirectory: true)

    /// The file `RTSRAGFileStore` keeps its log in. Checked before opening anything, because a
    /// directory without one opens as a perfectly valid **empty** store — so a mis-picked folder
    /// would answer every question with nothing and look like a corpus that simply had no match.
    private static let storeFileName = "entries.jsonl"

    func refreshRecentStores() {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: ResumeSearchViewModel.ragStoreRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        recentStores = (contents ?? [])
            .filter { url in
                FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(ResumeSearchViewModel.storeFileName).path
                )
            }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    func chooseFolder() {
        isShowingFolderPicker = true
    }

    func handleFolderChoice(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            open(url, isSecurityScoped: true)
        case .failure(let error):
            storeProblem = "could not open that folder: \(error.localizedDescription)"
        }
    }

    /// Opens `url` as a vector store, reporting what it holds and which embedder wrote it.
    func open(_ url: URL, isSecurityScoped: Bool) {
        releaseScope()
        store = nil
        storeSummary = nil
        storeProblem = nil
        answer = nil
        retrieved = []
        errorText = nil

        if isSecurityScoped, url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }
        selectedStore = url

        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent(ResumeSearchViewModel.storeFileName).path
        ) else {
            // The check that earns its place: without it this folder would open as an empty store
            // and every question would come back with nothing, indistinguishable from a real miss.
            storeProblem = "no vector store here — \(ResumeSearchViewModel.storeFileName) is missing."
            releaseScope()
            return
        }

        Task { [weak self] in
            await self?.inspect(url)
        }
    }

    private func inspect(_ url: URL) async {
        do {
            let opened = try RTSRAGFileStore(directory: url)
            let total = try await opened.count(matching: [:])
            guard let sample = try await opened.find(matching: [:], limit: 1).first else {
                storeProblem = "this store is empty — ingest something on the RAG tab first."
                releaseScope()
                return
            }
            store = opened
            // Pre-selected from what the store says wrote it. A wrong guess is not silent: the
            // runtime's own guard throws `embeddingModelMismatch` naming both models, and since
            // that check moved into `retrieve`, it fires before anything is paid to embed.
            embedder = EmbedderChoice.allCases.first {
                sample.embeddingModel.hasPrefix($0.identifierPrefix)
            } ?? embedder
            storeSummary = "\(total) chunk(s), written by \(sample.embeddingModel)"
        } catch {
            storeProblem = "could not open: \(error)"
            releaseScope()
        }
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: - Ask

    func ask() {
        guard let store, !question.isEmpty else {
            return
        }
        guard let apiKey = KeychainHelper.readAnthropicKey(), !apiKey.isEmpty else {
            errorText = "no Anthropic key in the Keychain"
            return
        }
        isRunning = true
        answer = nil
        errorText = nil
        retrieved = []
        let question = self.question
        let threshold = relevanceThreshold

        Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                isRunning = false
            }
            do {
                let embedding = try await makeEmbedder()
                let runtime = RTSRAGRetrievalRuntime(embedder: embedding, store: store)
                let tool = RTSKnowledgeSearchTool(
                    toolName: "SearchResumes",
                    toolDescription: """
                    Search the résumé corpus for passages about a candidate's skills, experience or \
                    qualifications. Returns passages with the file and page they came from. An \
                    empty result means no résumé covers it — say so rather than guessing.
                    """,
                    source: makeSource(runtime: runtime),
                    minimumScore: threshold > 0 ? threshold : nil
                )
                let agent = RTSAgent(
                    llmProvider: .anthropic(modelIDString: RTSAnthropicModelID.claudeSonnet46.modelIDString),
                    name: "Résumé Screener",
                    tools: [tool],
                    systemMessage: """
                    You screen job candidates using only the résumé corpus available through your \
                    search tool.

                    Always search before answering — never answer from prior knowledge. Cite the \
                    file and page for every claim you make about a candidate. If the search returns \
                    nothing, say plainly that no résumé in the corpus matches; do not soften it into \
                    a guess or offer a candidate you were not shown.
                    """
                )
                let gateway = RTSLLMGateway(apiKeys: [.anthropic: apiKey])
                let flow = RTSFlow(title: "Résumé search")
                answer = try await flow.run(agent: agent, prompt: question, gateway: gateway)
            } catch {
                errorText = "\(error)"
            }
        }
    }

    /// The mapping this whole phase exists to compile.
    ///
    /// `source` is dug out of metadata rather than read off a property: `RTSRAGStoreEntry` has no
    /// `source`, the path lives under `MetadataKey.sourcePath` — and `RTSRAGPDFLoader` writes it as
    /// `<path>#page-N`, so a citation names the file *and* the page with no extra work.
    ///
    /// The closure records as well as maps, so the view can show what the agent was handed. That
    /// dual use is what makes a closure conformer the right shape here, and is why no bridge target
    /// between the two modules was needed.
    private func makeSource(runtime: RTSRAGRetrievalRuntime) -> RTSClosureKnowledgeSource {
        RTSClosureKnowledgeSource { [weak self] query in
            let result = try await runtime.retrieve(query.text, topK: query.topK)
            let hits = result.entries.map { hit -> RTSKnowledgeHit in
                var source: String?
                if case .string(let path)? = hit.entry.metadata[RTSRAGChunk.MetadataKey.sourcePath] {
                    source = path
                }
                return RTSKnowledgeHit(
                    content: hit.entry.content,
                    source: source,
                    score: Double(hit.score),
                    metadata: ResumeSearchViewModel.convert(hit.entry.metadata)
                )
            }
            await self?.record(hits)
            return hits
        }
    }

    private func record(_ hits: [RTSKnowledgeHit]) {
        retrieved.append(contentsOf: hits)
    }

    /// `RTSRAGMetadataValue` → `RTSValue`. Two JSON-shaped enums in two modules that cannot see
    /// each other, so somebody has to write this; a shared conversion on the RAG side would remove
    /// it from every consumer.
    private static nonisolated func convert(_ metadata: RTSRAGMetadata) -> [String: RTSValue] {
        metadata.mapValues { convert($0) }
    }

    private static nonisolated func convert(_ value: RTSRAGMetadataValue) -> RTSValue {
        switch value {
        case .string(let text):
            return .string(text)
        case .integer(let number):
            return .number(Double(number))
        case .double(let number):
            return .number(number)
        case .boolean(let flag):
            return .bool(flag)
        case .array(let values):
            return .array(values.map { convert($0) })
        case .object(let fields):
            return .object(fields.mapValues { convert($0) })
        }
    }

    private func makeEmbedder() async throws -> any RTSRAGEmbedding {
        switch embedder {
        case .apple:
            let apple = try RTSRAGAppleEmbedding()
            try await apple.prepare()
            return apple
        case .openAI:
            guard let key = KeychainHelper.readOpenAIKey(), !key.isEmpty else {
                throw ResumeSearchError.missingOpenAIKey
            }
            return RTSRAGOpenAIEmbedding(apiKey: key)
        }
    }
}

enum ResumeSearchError: Error, CustomStringConvertible {
    case missingOpenAIKey

    var description: String {
        switch self {
        case .missingOpenAIKey:
            return "this store was written by OpenAI embeddings, but there is no OpenAI key in the Keychain"
        }
    }
}
