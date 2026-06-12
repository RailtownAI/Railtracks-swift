//
//  OutputSchemaView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-06-01.
//

import SwiftUI
import Logging

struct OutputSchemaView: View {
    @State private var viewModel = OutputSchemaViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Instruction: paste in the URL of the job post and click run")
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt from Job posting URL: ").font(.headline)
                TextField(
                    "https://…",
                    text: $viewModel.jobURLString
                )
                .textFieldStyle(.roundedBorder)
            }
            
            Button("Run") {
                viewModel.startPrompt()
            }
            .disabled(viewModel.jobURLString.isEmpty || viewModel.isRunning)
            .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
                APIKeySetupView(isUpdate: false) {
                    viewModel.isShowingKeyPrompt = false
                    viewModel.startPrompt()
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Result:")
                TextField(
                    "Result",
                    text: $viewModel.promptResult,
                    axis: .vertical
                )
                .lineLimit(8...16)
                .textFieldStyle(.roundedBorder)
                .padding()
            }
        }
        .padding()
    }
}

#Preview {
    OutputSchemaView()
}
