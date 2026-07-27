//
//  SimplePromptView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import SwiftUI
import Logging

struct SimplePromptView: View {
    @State private var viewModel = SimplePromptViewModel()

    var body: some View {
        VStack(spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            Text("Result: " + (viewModel.promptResult ?? ""))
            Button("Run") {
                viewModel.startPrompt()
            }
            .disabled(viewModel.isRunning)
            .buttonStyle(.bordered)
        }
        .padding()
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(provider: .anthropic, isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                viewModel.startPrompt()
            }
        }
    }
}

#Preview {
    SimplePromptView()
}
