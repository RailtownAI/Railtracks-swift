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
        VStack(spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            Text("Result: " + (viewModel.promptResult ?? "waiting..."))
        }
        .padding()
        .task {
            Log.debug("start math verify task...")
            viewModel.startPrompt()
        }
    }
}

#Preview {
    MathVerifyView()
}
