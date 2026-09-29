//
//  MathClaudeView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-24.
//
//  RailtracksSwiftDemoOS27 target only — see MathClaudeViewModel.swift.
//

import SwiftUI
import RailtracksSwiftUI

@available(macOS 27, iOS 27, *)
struct MathClaudeView: View {
    @State private var viewModel = MathClaudeViewModel()

    var body: some View {
        // Scrolls as a whole: after both paths have run, the result, the summary table and a call
        // tree holding two runs can outgrow the window.
        ScrollView {
            VStack(spacing: 8) {
                Text("Prompt: " + viewModel.prompt)
                HStack {
                    ForEach(MathClaudeViewModel.Path.allCases) { path in
                        Button("Run via \(path.rawValue)") {
                            viewModel.run(via: path)
                        }
                        .disabled(viewModel.isRunning)
                        .buttonStyle(.bordered)
                    }
                }

                VStack {
                    Text("Result:")
                    TextField(
                        "Result",
                        text: $viewModel.promptResult,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .padding()

                    summaryTable

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Call tree:").font(.caption).foregroundStyle(.secondary)
                        // The tree scrolls itself; inside this scroll view it needs a set height,
                        // or it collapses.
                        RTSNodeTreeView(viewModel: viewModel.nodeTree)
                            .frame(minHeight: 180)
                    }
                }
            }
            .padding()
        }
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(provider: .anthropic, isUpdate: false) {
                viewModel.resumeAfterKeySaved()
            }
        }
    }

    /// The latest run per path, side by side. A path not yet run shows dashes.
    private var summaryTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("")
                ForEach(MathClaudeViewModel.Path.allCases) { path in
                    Text(path.rawValue).bold()
                }
            }
            summaryRow("Round trips") { String($0.roundTrips) }
            summaryRow("Input tokens") { String($0.inputTokens) }
            summaryRow("Output tokens") { String($0.outputTokens) }
            summaryRow("Cost") { summary in
                summary.cost.map { String(format: "$%.5f", $0) } ?? "not priced"
            }
            summaryRow("Trace") { $0.traceStatus }
        }
        .font(.caption)
    }

    private func summaryRow(
        _ label: String,
        value: @escaping (MathClaudeViewModel.RunSummary) -> String
    ) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            ForEach(MathClaudeViewModel.Path.allCases) { path in
                Text(viewModel.summaries[path].map(value) ?? "—")
            }
        }
    }
}

@available(macOS 27, iOS 27, *)
#Preview {
    MathClaudeView()
}
