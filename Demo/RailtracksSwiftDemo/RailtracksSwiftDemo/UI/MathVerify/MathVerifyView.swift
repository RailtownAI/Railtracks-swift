//
//  MathVerifyView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-20.
//

import SwiftUI
import RailtracksSwiftUI
import Logging

struct MathVerifyView: View {
    @State private var viewModel = MathVerifyViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            HStack {
                Button("Run") {
                    viewModel.startPrompt()
                }
                .disabled(viewModel.isRunning)
                .buttonStyle(.bordered)

                Button("Stop", role: .cancel) {
                    viewModel.stopPrompt()
                }
                .disabled(!viewModel.isRunning)
                .buttonStyle(.bordered)
            }

            if !viewModel.nodeStatusLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Node Activity:").font(.caption).foregroundStyle(.secondary)
                    let log = viewModel.nodeStatusLines.joined(separator: "\n")
                    TextField("", text: .constant(log), axis: .vertical)
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...8)
                        .disabled(true)
                }
            }
            Text("Result: " + (viewModel.promptResult ?? ""))

            VStack(alignment: .leading, spacing: 4) {
                Text("Call tree:").font(.caption).foregroundStyle(.secondary)
                RTSNodeTreeView(viewModel: viewModel.nodeTree)
                    .frame(minHeight: 200)
            }
        }
        .padding()
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(provider: .openAI, isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                viewModel.startPrompt()
            }
        }
    }
}

#Preview {
    MathVerifyView()
}
