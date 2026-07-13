//
//  MathErrorView.swift
//  RailtracksSwiftDemo
//

import SwiftUI
import Logging

struct MathErrorView: View {
    @State private var viewModel = MathErrorViewModel()

    var body: some View {
        VStack(spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            HStack {
                Button("Run") {
                    viewModel.startPrompt()
                }
                .disabled(viewModel.isRunning)
                .buttonStyle(.bordered)

                Button("Force Throw", role: .destructive) {
                    viewModel.startForceThrow()
                }
                .disabled(viewModel.isRunning)
                .buttonStyle(.bordered)
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

                if !viewModel.traceStatus.isEmpty {
                    Text(viewModel.traceStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                viewModel.startPrompt()
            }
        }
    }
}

#Preview {
    MathErrorView()
}
