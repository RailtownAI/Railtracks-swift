//
//  EvaluationView.swift
//  RailtracksSwiftDemo
//

import SwiftUI
import RailtracksSwift

/// Evaluation demo: pick trace groups (by originating demo flow), choose evaluators, run, and see the
/// report summary + output path. Traces come from running the other demos first.
struct EvaluationView: View {
    @State private var viewModel = EvaluationViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Evaluation")
                    .font(.headline)

                HStack {
                    Text("Traces (grouped by demo flow)")
                        .font(.subheadline)
                    Spacer()
                    Button("Refresh") {
                        viewModel.scanTraces()
                    }
                    .font(.caption)
                }

                if viewModel.groups.isEmpty {
                    Text("No traces found. Run a demo (Math, Guardrails, …) first to generate traces.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(viewModel.groups) { group in
                        Toggle(isOn: Binding(
                            get: { group.isSelected },
                            set: { _ in viewModel.toggleGroup(group.id) }
                        )) {
                            Text("\(group.label)  (\(group.files.count))")
                        }
                    }
                }

                Divider()

                Text("Evaluators")
                    .font(.subheadline)
                Toggle("Tool Use", isOn: $viewModel.includeToolUse)
                Toggle("LLM Inference", isOn: $viewModel.includeLLMInference)
                Toggle(isOn: $viewModel.includeJudge) {
                    Text(viewModel.hasOpenAIKey
                         ? "Judge — Helpfulness (OpenAI)"
                         : "Judge — needs OpenAI key")
                }
                .disabled(!viewModel.hasOpenAIKey)

                Toggle("Save judge traces", isOn: $viewModel.saveJudgeTraces)
                    .font(.caption)
                    .padding(.leading, 20)
                    .disabled(!viewModel.includeJudge)

                Button(viewModel.isRunning ? "Evaluating…" : "Run Evaluation") {
                    viewModel.run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canRun)

                if !viewModel.summary.isEmpty {
                    Text(viewModel.summary)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.onAppear()
        }
    }
}

#Preview {
    EvaluationView()
}
