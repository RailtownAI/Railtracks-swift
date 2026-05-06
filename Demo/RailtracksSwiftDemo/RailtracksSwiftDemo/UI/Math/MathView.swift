//
//  MathView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import SwiftUI
import Logging

struct MathView: View {
    @State private var viewModel = MathViewModel()
    
    var body: some View {
        VStack(spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            Text("Result: " + (viewModel.promptResult ?? "waiting..."))
        }
        .padding()
        .task {
            Log.debug("start math task...")
            viewModel.startPrompt()
        }
    }
}

#Preview {
    MathView()
}
