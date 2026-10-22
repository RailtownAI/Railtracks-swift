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
            // Scrolls sideways rather than wrapping: on iPhone the buttons outgrow one row, and
            // extra rows would push the demo itself down, since this header does not scroll.
            ScrollView(.horizontal, showsIndicators: false) {
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

                    // RailtracksSwiftDemoOS27 target only — see MathClaudeViewModel.swift.
                    #if OS27
                    if #available(macOS 27, iOS 27, *) {
                        Button("Math(Claude)") {
                            viewModel.mode = .mathClaude
                        }
                        .background(viewModel.mode == .mathClaude ? Color.accentColor.opacity(0.2) : Color.clear)
                        .buttonStyle(.bordered)
                    }
                    #endif

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

                    Button("Evaluation") {
                        viewModel.mode = .evaluation
                    }
                    .background(viewModel.mode == .evaluation ? Color.accentColor.opacity(0.2) : Color.clear)
                    .buttonStyle(.bordered)

                    Button("Vision") {
                        viewModel.mode = .vision
                    }
                    .background(viewModel.mode == .vision ? Color.accentColor.opacity(0.2) : Color.clear)
                    .buttonStyle(.bordered)

                    Button("RAG") {
                        viewModel.mode = .rag
                    }
                    .background(viewModel.mode == .rag ? Color.accentColor.opacity(0.2) : Color.clear)
                    .buttonStyle(.bordered)

                    Button("RAG (Spotlight)") {
                        viewModel.mode = .ragSpotlight
                    }
                    .background(viewModel.mode == .ragSpotlight ? Color.accentColor.opacity(0.2) : Color.clear)
                    .buttonStyle(.bordered)

                    Button("Apple Embedding") {
                        viewModel.mode = .appleEmbedding
                    }
                    .background(viewModel.mode == .appleEmbedding ? Color.accentColor.opacity(0.2) : Color.clear)
                    .buttonStyle(.bordered)

                    Button("Résumé Search") {
                        viewModel.mode = .resumeSearch
                    }
                    .background(viewModel.mode == .resumeSearch ? Color.accentColor.opacity(0.2) : Color.clear)
                    .buttonStyle(.bordered)
                }
            }
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Railtracks Swift Lib Version: " + viewModel.libVersion)
            HStack(spacing: 8) {
                Text("Anthropic key: \(viewModel.hasAnthropicKey ? "✓" : "✗")")
                Button("Update") {
                    viewModel.updateProvider = .anthropic
                    viewModel.isShowingKeyUpdate = true
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                Text("Gemini key: \(viewModel.hasGeminiKey ? "✓" : "✗")")
                Button("Update") {
                    viewModel.updateProvider = .gemini
                    viewModel.isShowingKeyUpdate = true
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                Text("OpenAI key: \(viewModel.hasOpenAIKey ? "✓" : "✗")")
                Button("Update") {
                    viewModel.updateProvider = .openAI
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
            #if OS27
            case .mathClaude:
                if #available(macOS 27, iOS 27, *) {
                    MathClaudeView()
                }
            #endif
            case .mathVerify:
                MathVerifyView()
            case .mathError:
                MathErrorView()
            case .outputSchema:
                OutputSchemaView()
            case .guardrails:
                GuardrailsView()
            case .evaluation:
                EvaluationView()
            case .vision:
                VisionView()
            case .rag:
                RAGView()
            case .ragSpotlight:
                RAGSpotlightView()
            case .appleEmbedding:
                AppleEmbeddingView()
            case .resumeSearch:
                ResumeSearchView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding()
        .onAppear {
            viewModel.checkKeychain()
        }
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(provider: viewModel.promptProvider, isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                // Re-check next run loop so a second missing key re-presents cleanly.
                DispatchQueue.main.async { viewModel.checkKeychain() }
            }
        }
        .sheet(isPresented: $viewModel.isShowingKeyUpdate) {
            APIKeySetupView(provider: viewModel.updateProvider, isUpdate: true) {
                viewModel.isShowingKeyUpdate = false
                viewModel.refreshKeyStatus()
            }
        }
    }
}

#Preview {
    ContentView()
}
