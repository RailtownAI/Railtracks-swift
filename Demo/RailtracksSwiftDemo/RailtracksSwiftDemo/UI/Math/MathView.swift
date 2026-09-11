//
//  MathView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import SwiftUI
import RailtracksSwiftUI
import Logging

struct MathView: View {
    @State private var viewModel = MathViewModel()

    var body: some View {
        VStack(spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            Button("Run") {
                viewModel.startPrompt()
            }
            .disabled(viewModel.isRunning)
            .buttonStyle(.bordered)

            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sequential").font(.caption).foregroundStyle(.secondary)
                    RTSStepsView(steps: viewModel.sequentialSteps)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Parallel").font(.caption).foregroundStyle(.secondary)
                    RTSStepsView(steps: viewModel.parallelSteps)
                }
            }
            .padding(.vertical)

            VStack {
                Text("Result:")
                TextField(
                    "Result",
                    text: $viewModel.promptResult,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .padding()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Call tree:")
                RTSNodeTreeView(viewModel: viewModel.nodeTree)
                    .frame(minHeight: 160)
            }

            if !viewModel.eventLogSummary.isEmpty {
                Text(viewModel.eventLogSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .padding()
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(provider: .gemini, isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                viewModel.startPrompt()
            }
        }
    }
}

#Preview {
    MathView()
}
