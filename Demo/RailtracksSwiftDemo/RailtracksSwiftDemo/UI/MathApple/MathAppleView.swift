//
//  MathAppleView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-28.
//

import SwiftUI
import Logging

struct MathAppleView: View {
    @State private var viewModel = MathAppleViewModel()

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
            Log.debug("start math apple task...")
            viewModel.startPrompt()
        }
    }
}

#Preview {
    MathAppleView()
}
