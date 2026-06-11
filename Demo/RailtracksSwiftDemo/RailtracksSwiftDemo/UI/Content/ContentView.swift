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
                .background(viewModel.mode == .simple ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(8)

                Button("Math") {
                    viewModel.mode = .math
                }
                .background(viewModel.mode == .math ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(8)
                
                Button("Math(AppleAI)") {
                    viewModel.mode = .mathApple
                }
                .background(viewModel.mode == .mathApple ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(8)
                
                Button("Verified Math") {
                    viewModel.mode = .mathVerify
                }
                .background(viewModel.mode == .mathVerify ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(8)
                
                Button("Math Error") {
                    viewModel.mode = .mathError
                }
                .background(viewModel.mode == .mathError ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(8)

                Button("Output Schema") {
                    viewModel.mode = .outputSchema
                }
                .background(viewModel.mode == .outputSchema ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(8)
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
            case .mathApple:
                MathAppleView()
            case .mathVerify:
                MathVerifyView()
            case .mathError:
                MathErrorView()
            case .outputSchema:
                OutputSchemaView()
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
