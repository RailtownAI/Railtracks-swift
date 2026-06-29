//
//  GuardrailsView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-06-29.
//

import SwiftUI
import Logging

struct GuardrailsView: View {
    @State private var viewModel = GuardrailsViewModel()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(viewModel.presets) { preset in
                    Button(preset.label) {
                        viewModel.usePreset(preset)
                    }
                    .buttonStyle(.bordered)
                }
            }
            TextField("Prompt", text: $viewModel.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
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
    }
}

#Preview {
    GuardrailsView()
}
