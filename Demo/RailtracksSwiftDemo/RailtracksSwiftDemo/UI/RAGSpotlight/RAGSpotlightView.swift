//
//  RAGSpotlightView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-28.
//

import SwiftUI
import UniformTypeIdentifiers

/// Ingest PDFs into Spotlight, then search them with `CSUserQuery`.
///
/// A trimmed-down `RAGView`: no format, chunker or embedder pickers — Spotlight embeds for itself,
/// and the loader and chunker are fixed so the screen isolates the Spotlight path.
struct RAGSpotlightView: View {
    @State private var viewModel = RAGSpotlightViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                inputSection
                Divider()
                statusSection
                Divider()
                searchSection
            }
            .padding()
        }
        .fileImporter(
            isPresented: $viewModel.isShowingFileImporter,
            allowedContentTypes: [.folder, .pdf],
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleImport(result)
        }
        .onAppear {
            viewModel.prepare()
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PDF, one document per page · sentence chunker · default Spotlight index")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Choose PDF or Folder") {
                    viewModel.selectPath()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRunning)

                Text(viewModel.selectedPath?.lastPathComponent ?? "nothing selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button("Ingest") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)

                Button("Cancel") {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isRunning)

                Spacer()

                // Scoped to this feeder's namespace, so it cannot remove anything else the app
                // donated to Spotlight.
                Button("Clear Spotlight") {
                    viewModel.clearSpotlight()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRunning)
            }

            HStack(spacing: 8) {
                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Status:")
                Spacer()
                Button("Clear") {
                    viewModel.clearLog()
                }
                .font(.caption)
                .disabled(viewModel.statusLog.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.statusLog.isEmpty ? "No activity yet." : viewModel.statusLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(viewModel.statusLog.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.logBottomAnchor)
                }
                .frame(height: 180)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: viewModel.statusLog) {
                    proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Search

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Spotlight:")

            HStack(spacing: 8) {
                TextField("what does the document say about…", text: $viewModel.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.search()
                    }

                Toggle("Semantic", isOn: $viewModel.usesSemanticSearch)
                    .toggleStyle(.button)

                Button("Search") {
                    viewModel.search()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canSearch)

                if viewModel.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let note = viewModel.searchNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.hits) { hit in
                hitRow(hit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hitRow(_ hit: RAGSpotlightViewModel.Hit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hitHeader(hit))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(hit.text.prefix(300) + (hit.text.count > 300 ? "…" : ""))
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
            if let url = hit.contentURL {
                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    /// Rank is arrival order: `CSUserQuery` returns ranked items but no score.
    private func hitHeader(_ hit: RAGSpotlightViewModel.Hit) -> String {
        let chunk = hit.chunkIndex.map { " · chunk \($0)" } ?? ""
        return "#\(hit.rank + 1)  \(hit.title)\(chunk)  ·  \(hit.text.count) chars"
    }

    private static let logBottomAnchor = "rag-spotlight-status-log-bottom"
}

#Preview {
    RAGSpotlightView()
}
