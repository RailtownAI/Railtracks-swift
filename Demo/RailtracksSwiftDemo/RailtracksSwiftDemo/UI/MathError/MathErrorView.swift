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
        .task {
            Log.debug("start math error task...")
            viewModel.startPrompt()
        }
    }
}

#Preview {
    MathErrorView()
}
