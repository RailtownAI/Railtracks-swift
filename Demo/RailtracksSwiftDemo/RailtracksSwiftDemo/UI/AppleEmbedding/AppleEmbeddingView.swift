//
//  AppleEmbeddingView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-10-21.
//

import SwiftUI

/// Try the on-device embedder's three entry points — check, load without downloading, prepare with
/// a timeout — and cancel a prepare while it waits. See `AppleEmbeddingViewModel`.
struct AppleEmbeddingView: View {
    @State private var viewModel = AppleEmbeddingViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                inputSection
                Divider()
                statusSection
            }
            .padding()
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.environmentNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Language", selection: $viewModel.languageChoice) {
                ForEach(AppleEmbeddingViewModel.LanguageChoice.allCases) { choice in
                    Text(choice.title)
                        .tag(choice)
                }
            }
            .pickerStyle(.menu)

            Picker("Prepare timeout", selection: $viewModel.timeoutChoice) {
                ForEach(AppleEmbeddingViewModel.TimeoutChoice.allCases) { choice in
                    Text(choice.title)
                        .tag(choice)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button("Check Assets") {
                    viewModel.checkAssets()
                }
                .buttonStyle(.bordered)

                Button("Load If Available") {
                    viewModel.loadIfAvailable()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                // Tap more than once for concurrent callers: they share one request.
                Button("Prepare") {
                    viewModel.startPrepare()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    viewModel.cancelWaiting()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.waitingCount == 0)

                Button("Embed Sample") {
                    viewModel.embedSample()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.readyEmbedder == nil)
            }

            HStack(spacing: 8) {
                if viewModel.waitingCount > 0 {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(viewModel.waitingCount) caller(s) waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The library logs the asset request itself, and its real result, to the console.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .frame(height: 260)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: viewModel.statusLog) {
                    proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let logBottomAnchor = "apple-embedding-status-log-bottom"
}

#Preview {
    AppleEmbeddingView()
}
