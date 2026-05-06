//
//  ContentView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import SwiftUI
import Logging

struct ContentView: View {
    @State private var viewModel = ContentViewModel()
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Button("Simple") {
                    viewModel.mode = .simple
                }
                
                Button("Math") {
                    viewModel.mode = .math
                }
            }
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Railtracks Swift Lib Version: " + viewModel.libVersion)
            Text("Has OpenAI key:  \(viewModel.openAIAPIKey.isNotNilNorEmpty ? "true" : "false")")
            switch viewModel.mode {
            case .simple:
                SimplePromptView()
            case .math:
                MathView()
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
