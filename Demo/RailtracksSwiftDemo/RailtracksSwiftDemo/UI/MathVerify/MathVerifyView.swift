//
//  MathVerifyView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-20.
//

import SwiftUI
import RailtracksSwiftUI
import Logging

struct MathVerifyView: View {
    @State private var viewModel = MathVerifyViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt: " + viewModel.prompt)
            HStack {
                Button("Run") {
                    viewModel.startPrompt()
                }
                .disabled(viewModel.isRunning)
                .buttonStyle(.bordered)

                Button("Stop", role: .cancel) {
                    viewModel.stopPrompt()
                }
                .disabled(!viewModel.isRunning)
                .buttonStyle(.bordered)

                Picker("Timeout", selection: $viewModel.timeout) {
                    Text("None").tag(TimeInterval?.none)
                    Text("3 s").tag(TimeInterval?.some(3))
                    Text("30 s").tag(TimeInterval?.some(30))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(viewModel.isRunning)
            }

            if !viewModel.nodeStatusLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Node Activity:").font(.caption).foregroundStyle(.secondary)
                    // A scroll view rather than a disabled text field: the field stopped growing at
                    // its line limit and couldn't be scrolled, hiding the last lines, which are the
                    // ones a stop produces.
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(viewModel.nodeStatusLines.indices, id: \.self) { index in
                                    Text(viewModel.nodeStatusLines[index])
                                        .font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding(6)
                        }
                        .textSelection(.enabled)
                        .frame(height: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.4))
                        )
                        .onChange(of: viewModel.nodeStatusLines.count) { _, count in
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            Text("Result: " + (viewModel.promptResult ?? ""))

            VStack(alignment: .leading, spacing: 4) {
                Text("Call tree:").font(.caption).foregroundStyle(.secondary)
                RTSNodeTreeView(viewModel: viewModel.nodeTree)
                    .frame(minHeight: 200)
            }
        }
        .padding()
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(provider: .openAI, isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                viewModel.startPrompt()
            }
        }
    }
}

#Preview {
    MathVerifyView()
}
