//
//  MathView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-04.
//

import SwiftUI
import Logging

struct MathView: View {
    var logger = Logger(label: "railtracks-swift-demo")
    
    var prompt: String = "What is 50 / 2 + 20 x 9? Just give me the final answer"
    var promptResult: String?
    
    @State private var viewModel = MathViewModel()
    
    var body: some View {
        VStack(spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            Text("Result: " + (viewModel.promptResult ?? "waiting..."))
        }
        .padding()
        .task {
            print("start task...")
            viewModel.startPrompt()
        }
    }
}

#Preview {
    MathView()
}
