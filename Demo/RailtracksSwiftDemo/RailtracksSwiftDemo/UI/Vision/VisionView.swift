//
//  VisionView.swift
//  RailtracksSwiftDemo
//

import SwiftUI
import PhotosUI
import Logging
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct VisionView: View {
    @State private var viewModel = VisionViewModel()
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 12) {
            Text("Pick a photo and a model, then Run to get a summary.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Model", selection: $viewModel.model) {
                ForEach(VisionViewModel.Model.allCases) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Pick a Photo")
            }
            .buttonStyle(.bordered)

            if let picked = pickedImage {
                picked
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 160)
                    .overlay(Text("No photo selected").foregroundStyle(.secondary))
            }

            Button("Run") {
                viewModel.startPrompt()
            }
            .disabled(viewModel.pickedImageData == nil || viewModel.isRunning)
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 4) {
                Text("Summary:")
                TextField(
                    "Summary",
                    text: $viewModel.promptResult,
                    axis: .vertical
                )
                .lineLimit(4...12)
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding()
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else {
                return
            }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    viewModel.setPickedImage(data)
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingKeyPrompt) {
            APIKeySetupView(provider: viewModel.model.keyProvider ?? .gemini, isUpdate: false) {
                viewModel.isShowingKeyPrompt = false
                viewModel.startPrompt()
            }
        }
    }

    private var pickedImage: Image? {
        guard let data = viewModel.pickedImageData else {
            return nil
        }
        #if canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #endif
        return nil
    }
}

#Preview {
    VisionView()
}
