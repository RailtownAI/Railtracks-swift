//
//  MathVerifyView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-20.
//

import SwiftUI
import Logging

struct MathVerifyView: View {
    @State private var viewModel = MathVerifyViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            Button("Run") {
                viewModel.startPrompt()
            }
            .disabled(viewModel.isRunning)
            if !viewModel.nodeStatusLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Node Activity:").font(.caption).foregroundStyle(.secondary)
                    TextField(
                        "",
                        text: $viewModel.nodeStatusLog,
                        axis: .vertical
                    )
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .disabled(true)
                }
            }
            Text("Result: " + (viewModel.promptResult ?? ""))
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
    MathVerifyView()
}
