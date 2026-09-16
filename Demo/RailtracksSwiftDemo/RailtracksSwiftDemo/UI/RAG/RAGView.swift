//
//  RAGView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-15.
//

import SwiftUI
import RailtracksSwiftRAG

/// Trigger and progress view for the RAG ingest pipeline.
///
/// Deliberately phase-shaped rather than loader-shaped: the status log attributes every line to
/// Resolve / Load / Chunk / Embed / Store, and names the three that do not exist yet, so the
/// screen keeps working as each phase lands.
struct RAGView: View {
    @State private var viewModel = RAGViewModel()

    var body: some View {
        // The whole page scrolls: an expanded preview of a long document plus its chunks runs well
        // past the window, and the status log's own scroll view only covers the log.
        ScrollView {
            VStack(spacing: 16) {
                inputSection
                Divider()
                statusSection
            }
            .padding()
        }
        .fileImporter(
            isPresented: $viewModel.isShowingFileImporter,
            allowedContentTypes: viewModel.format.contentTypes,
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleImport(result)
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Format", selection: $viewModel.format) {
                ForEach(RAGViewModel.Format.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)

            Text("\(viewModel.format.granularityNote)\n\(viewModel.format.chunkerNote)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Embedder", selection: $viewModel.embedder) {
                ForEach(RAGViewModel.EmbedderChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)

            Text(viewModel.embedder.note)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Select File or Folder…") {
                viewModel.selectPath()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRunning)

            Text(viewModel.selectedPath?.path ?? "No file or folder selected")
                .font(.caption)
                .foregroundStyle(viewModel.selectedPath == nil ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Start") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)

                if viewModel.isRunning {
                    Button("Cancel") {
                        viewModel.cancel()
                    }
                    .buttonStyle(.bordered)

                    ProgressView()
                        .controlSize(.small)
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressText: String {
        "file \(viewModel.sourcesProcessed)/\(viewModel.sourceTotal)"
            + " · \(viewModel.documentCount) doc(s)"
            + " · \(viewModel.chunkCount) chunk(s)"
            + " · \(viewModel.embeddedCount) embedded"
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

                Button("Copy") {
                    viewModel.copyLog()
                }
                .font(.caption)
                .disabled(viewModel.statusLog.isEmpty)
            }

            statusLog

            if let document = viewModel.previewDocument {
                documentPreview(document)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A scrolling log rather than a `TextField`.
    ///
    /// A vertical-axis `TextField` grows to its `lineLimit` maximum and then clips — it hosts no
    /// scroll view, so wheel and trackpad gestures have nothing to drive and older lines become
    /// unreachable. A `ScrollView` also buys the thing a run actually needs: the view follows the
    /// tail as lines arrive, so progress stays visible without being chased.
    private var statusLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(viewModel.statusLog.isEmpty ? "No activity yet." : viewModel.statusLog)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(viewModel.statusLog.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                // Zero-height anchor: scrolling to the last line of wrapped text is unreliable,
                // scrolling to a marker past it is not.
                Color.clear
                    .frame(height: 1)
                    .id(Self.logBottomAnchor)
            }
            .frame(height: 220)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: viewModel.statusLog) {
                proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let logBottomAnchor = "rag-status-log-bottom"

    /// The first document of the run. Worth showing because "document" means something different
    /// per format — a whole file for text, a single row for CSV, one page for PDF — and the count
    /// alone does not reveal that.
    private func documentPreview(_ document: RTSRAGDocument) -> some View {
        DisclosureGroup("First document", isExpanded: $viewModel.isShowingPreview) {
            VStack(alignment: .leading, spacing: 4) {
                previewRow("source", document.source ?? "nil")
                previewRow("type", document.type.rawValue)
                previewRow("id", document.id.description)
                previewRow("metadata", document.metadata.isEmpty ? "none" : "\(document.metadata.count) key(s)")
                excerpt(document.content)

                // The chunks this document produced, which is where the two chunkers visibly
                // differ: identity returns the document unchanged, sentence returns slices.
                if !viewModel.previewChunks.isEmpty {
                    Divider()
                    previewRow("chunks", "\(viewModel.previewChunks.count)")
                    ForEach(viewModel.previewChunks.prefix(3), id: \.id) { chunk in
                        Text("[\(chunk.index)] \(chunk.content.count) chars")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        excerpt(chunk.content)
                    }
                    if viewModel.previewChunks.count > 3 {
                        Text("…\(viewModel.previewChunks.count - 3) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func excerpt(_ content: String) -> some View {
        Text(content.prefix(400) + (content.count > 400 ? "…" : ""))
            .font(.system(.caption, design: .monospaced))
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .textSelection(.enabled)
    }

    private func previewRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}

#Preview {
    RAGView()
}
