//
//  MathAppleView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-28.
//

import SwiftUI
import Logging

@available(macOS 26, iOS 26, *)
struct MathAppleView: View {
    @State private var viewModel = MathAppleViewModel()

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
    }
}

@available(macOS 26, iOS 26, *)
#Preview {
    MathAppleView()
}
