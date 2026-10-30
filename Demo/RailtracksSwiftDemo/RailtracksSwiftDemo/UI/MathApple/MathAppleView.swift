//
//  MathAppleView.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-05-28.
//

import SwiftUI
import Logging

@available(macOS 26, iOS 26, *)
struct MathAppleView: View {
    @State private var viewModel = MathAppleViewModel()

    var body: some View {
        VStack(spacing: 8) {
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
            }

            if !viewModel.nodeStatusLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Node Activity:").font(.caption).foregroundStyle(.secondary)
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
    }
}

@available(macOS 26, iOS 26, *)
#Preview {
    MathAppleView()
}
