//
//  ResumeSearchView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-23.
//

import SwiftUI
import RailtracksSwift
import UniformTypeIdentifiers

/// An agent answering hiring questions from a corpus of résumés.
///
/// The screen shows the agent's answer **and** the passages its tool actually returned. That
/// pairing is the point: an answer on its own cannot be judged, and the interesting failure in
/// retrieval — plausible passages that do not answer the question — is invisible without it.
struct ResumeSearchView: View {
    @State private var viewModel = ResumeSearchViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                storeSection
                Divider()
                askSection
                if let answer = viewModel.answer {
                    Divider()
                    answerSection(answer)
                }
                if !viewModel.retrieved.isEmpty {
                    Divider()
                    retrievedSection
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $viewModel.isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleFolderChoice(result)
        }
        .onAppear {
            viewModel.refreshRecentStores()
        }
    }

    // MARK: - Store

    private var storeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vector store")
                .font(.headline)

            Text("Ingest a folder of résumé PDFs on the RAG tab first, then pick that store here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.recentStores.isEmpty {
                // The RAG tab names a store by a UUID it does not print a path for, so listing
                // what is actually on disk is what keeps this usable.
                ForEach(viewModel.recentStores, id: \.self) { url in
                    Button {
                        viewModel.open(url, isSecurityScoped: false)
                    } label: {
                        HStack {
                            Image(systemName: viewModel.selectedStore == url ? "largecircle.fill.circle" : "circle")
                            Text(url.lastPathComponent)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Button("Choose folder…") {
                    viewModel.chooseFolder()
                }
                .buttonStyle(.bordered)

                Button("Rescan") {
                    viewModel.refreshRecentStores()
                }
                .buttonStyle(.bordered)
            }

            if let summary = viewModel.storeSummary {
                // Naming the model matters: a store is only queryable by the embedder that wrote
                // it, and this is where a mismatch becomes obvious before a question is asked.
                Label(summary, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let problem = viewModel.storeProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Embedder", selection: $viewModel.embedder) {
                ForEach(ResumeSearchViewModel.EmbedderChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)

            Text("Pre-selected from the store's own record. Overriding it to the wrong one fails "
                + "with a model mismatch rather than returning nonsense.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ask

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about the candidates")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("who has CoreML experience?", text: $viewModel.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.ask()
                    }

                Button("Ask") {
                    viewModel.ask()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canAsk)

                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text("Relevance floor")
                    .font(.caption)
                Slider(value: $viewModel.relevanceThreshold, in: 0...1)
                    .frame(maxWidth: 220)
                Text(String(format: "%.2f", viewModel.relevanceThreshold))
                    .font(.system(.caption, design: .monospaced))
            }

            // The lesson this tab exists to make visible, stated where it will be read.
            Text(viewModel.relevanceThreshold == 0
                ? "At zero, a vector store answers every question with its nearest matches — even "
                    + "when nothing is relevant. Ask about a skill no résumé has and watch."
                : "Passages scoring below the floor are dropped, so \"nothing relevant\" becomes "
                    + "expressible. Raise it until unanswerable questions return nothing.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Results

    private func answerSection(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Answer")
                .font(.headline)
            Text(answer)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retrievedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the tool returned (\(viewModel.retrieved.count))")
                .font(.headline)
            Text("The agent saw exactly these. Compare them against the answer above.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(Array(viewModel.retrieved.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Self.citation(for: hit))  ·  score \(String(format: "%.3f", hit.score))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(hit.content.prefix(300) + (hit.content.count > 300 ? "…" : ""))
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `RTSRAGPDFLoader` writes a page's source as `<path>#page-N`, so file and page are both
    /// already there — split rather than parsed.
    private static func citation(for hit: RTSKnowledgeHit) -> String {
        guard let source = hit.source else {
            return "(no source)"
        }
        let parts = source.split(separator: "#", maxSplits: 1)
        let file = URL(fileURLWithPath: String(parts[0])).lastPathComponent
        guard parts.count > 1 else {
            return file
        }
        return "\(file) · \(parts[1].replacingOccurrences(of: "page-", with: "page "))"
    }
}

#Preview {
    ResumeSearchView()
}
