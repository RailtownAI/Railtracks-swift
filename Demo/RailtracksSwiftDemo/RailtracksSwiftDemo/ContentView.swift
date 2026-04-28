//
//  ContentView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import SwiftUI
import Logging

struct ContentView: View {
    var logger = Logger(label: "railtracks-swift-demo")
    
    @State private var viewModel = ContentViewModel()
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(viewModel.title)
            Text("Railtracks Lib Version: " + viewModel.libVersion)
            Text("Has OpenAI key \(viewModel.openAIAPIKey.isNotNilNorEmpty ? "true" : "false")")
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
    ContentView()
}
