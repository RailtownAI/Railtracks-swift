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
                .buttonStyle(.bordered)

                Button("Math") {
                    viewModel.mode = .math
                }
                .background(viewModel.mode == .math ? Color.accentColor.opacity(0.2) : Color.clear)
                .buttonStyle(.bordered)

                if #available(macOS 26, iOS 26, *) {
                    Button("Math(AppleAI)") {
                        viewModel.mode = .mathApple
                    }
                    .background(viewModel.mode == .mathApple ? Color.accentColor.opacity(0.2) : Color.clear)
                    .buttonStyle(.bordered)
                }

                Button("Verified Math") {
                    viewModel.mode = .mathVerify
                }
                .background(viewModel.mode == .mathVerify ? Color.accentColor.opacity(0.2) : Color.clear)
                .buttonStyle(.bordered)

                Button("Math Error") {
                    viewModel.mode = .mathError
                }
                .background(viewModel.mode == .mathError ? Color.accentColor.opacity(0.2) : Color.clear)
                .buttonStyle(.bordered)

                Button("Output Schema") {
                    viewModel.mode = .outputSchema
                }
                .background(viewModel.mode == .outputSchema ? Color.accentColor.opacity(0.2) : Color.clear)
                .buttonStyle(.bordered)

                Button("Guardrails") {
                    viewModel.mode = .guardrails
                }
                .background(viewModel.mode == .guardrails ? Color.accentColor.opacity(0.2) : Color.clear)
                .buttonStyle(.bordered)
            }
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Railtracks Swift Lib Version: " + viewModel.libVersion)
            HStack(spacing: 8) {
                Text("Has OpenAI key: \(viewModel.hasOpenAIKey ? "true" : "false")")
                Button("Update Key") {
                    viewModel.isShowingKeyUpdate = true
                }
                .font(.caption)
            }
            switch viewModel.mode {
            case .simple:
                SimplePromptView()
            case .math:
                MathView()
            case .mathApple:
                if #available(macOS 26, iOS 26, *) {
                    MathAppleView()
                }
            case .mathVerify:
                MathVerifyView()
            case .mathError:
                MathErrorView()
            case .outputSchema:
                OutputSchemaView()
            case .guardrails:
                GuardrailsView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding()
        .onAppear {
            viewModel.checkKeychain()
        }
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                viewModel.refreshKeyStatus()
            }
        }
        .sheet(isPresented: $viewModel.isShowingKeyUpdate) {
            APIKeySetupView(isUpdate: true) {
                viewModel.isShowingKeyUpdate = false
                viewModel.refreshKeyStatus()
            }
        }
    }
}

#Preview {
    ContentView()
}
