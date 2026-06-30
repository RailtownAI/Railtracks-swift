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
                    .background(
                        viewModel.isSelected(preset)
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                    )
                    .buttonStyle(.bordered)
                }
            }
            Text("Prompt: ").font(.headline)
            TextField("Prompt", text: $viewModel.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            Button("Run") {
                viewModel.startPrompt()
            }
            .disabled(viewModel.isRunning)
            .buttonStyle(.bordered)
            
            Divider()
            
            VStack {
                Text("Result:").font(.headline)
                TextField(
                    "Result",
                    text: $viewModel.promptResult,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            }
            .padding([.top, .bottom], 16)
        }
        .padding()
    }
}

#Preview {
    GuardrailsView()
}
