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
            Button("Run") {
                viewModel.startPrompt()
            }
            .disabled(viewModel.isRunning)
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
