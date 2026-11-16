//
//  VisionViewModel.swift
//  RailtracksSwiftDemo
//

import Foundation
import RailtracksSwift
import Logging
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if OS27
import ClaudeForFoundationModels
#endif

/// Vision demo: pick a photo, then ask a vision model to summarize it. Demonstrates multimodal
/// input — an `RTSImage` attached to the prompt via `flow.run(agent:prompt:images:)` — on Gemini
/// through Conduit, and on the Foundation Models path (on-device, and Claude in the OS 27 target).
@Observable
class VisionViewModel {
    /// The model a run is sent to.
    enum Model: String, CaseIterable, Identifiable {
        case gemini = "Gemini"
        /// The on-device system model. Takes images from OS 27; below it they are dropped with a
        /// warning and only the prompt is sent.
        case appleAI = "On-device"
        #if OS27
        /// Claude through Foundation Models (`.foundationModel`), rather than Conduit.
        case claudeFoundationModels = "Claude (FM)"
        #endif

        var id: Self {
            self
        }

        /// The key this model needs, or `nil` when it needs none.
        var keyProvider: DemoAPIKeyProvider? {
            switch self {
            case .gemini:
                return .gemini
            case .appleAI:
                return nil
            #if OS27
            case .claudeFoundationModels:
                return .anthropic
            #endif
            }
        }
    }

    let prompt: String = "Summarize what is shown in this image in a few sentences."
    var model: Model = .gemini
    /// Picked photo, normalized to JPEG for consistent provider support and display.
    var pickedImageData: Data?
    var promptResult: String = ""
    var isRunning = false
    var isShowingKeyPrompt = false

    /// Normalize picked photo data (which may be HEIC/PNG/…) to JPEG.
    func setPickedImage(_ data: Data) {
        let normalized = Self.jpegData(from: data) ?? data
        Self.logDimensions(original: data, normalized: normalized)
        pickedImageData = normalized
        promptResult = ""
    }

    /// Logs the pixel dimensions on both sides of the JPEG re-encode.
    ///
    /// Kept because image token cost is not readable from the image itself. On Gemini 3.x every
    /// `mediaResolution` level is a flat per-image allocation, so these dimensions do not change the
    /// cost at all; on 2.5 they matter only at `.high`, which tiles. What the two lines are actually
    /// for is confirming the picked photo reaches the provider at full size — whether
    /// `jpegData(from:)` shrank it — which affects the detail the model sees, not the token count.
    private static func logDimensions(original: Data, normalized: Data) {
        let describe: (Data) -> String = { data in
            guard let size = pixelSize(of: data) else {
                return "unreadable (\(data.count) bytes)"
            }
            return "\(size.width)×\(size.height) (\(data.count) bytes)"
        }
        Log.debug("🖼️ picked image: \(describe(original))")
        Log.debug("🖼️ after JPEG normalize: \(describe(normalized))")
    }

    /// True pixel dimensions, read from the image header rather than by decoding — `UIImage.size` is in
    /// points, so it would need scaling to mean anything here.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    func startPrompt() {
        let apiKey: String?
        switch model.keyProvider {
        case .gemini:
            apiKey = KeychainHelper.readGeminiKey()
        case .anthropic:
            apiKey = KeychainHelper.readAnthropicKey()
        case .openAI:
            apiKey = KeychainHelper.readOpenAIKey()
        case nil:
            apiKey = ""
        }
        guard let apiKey else {
            isShowingKeyPrompt = true
            return
        }
        guard let imageData = pickedImageData else {
            return
        }
        isRunning = true
        promptResult = ""
        let prompt = self.prompt
        let model = self.model
        Task { [weak self] in
            defer { self?.isRunning = false }
            let (provider, gateway) = Self.providerAndGateway(for: model, apiKey: apiKey)
            let flow = RTSFlow(title: "Image Summary (\(model.rawValue))")
            let agent = RTSAgent(
                llmProvider: provider,
                name: "Image Summarizer",
                systemMessage: "You are a helpful assistant that describes and summarizes images."
            )
            let image = RTSImage(data: imageData, mimeType: "image/jpeg")
            Log.debug("🖼️ starting image summary on \(model.rawValue)...")
            do {
                let result = try await flow.run(
                    agent: agent,
                    prompt: prompt,
                    gateway: gateway,
                    images: [image]
                )
                self?.promptResult = result
            } catch {
                self?.promptResult = "Error: \(error)"
            }
            Log.debug("🖼️ image summary finished")
        }
    }

    /// The agent's provider and the gateway it runs through. Only Gemini puts its key in the gateway:
    /// the on-device model needs none, and Claude through Foundation Models carries its own auth.
    private static func providerAndGateway(
        for model: Model,
        apiKey: String
    ) -> (RTSLLMProvider, RTSLLMGateway) {
        switch model {
        case .gemini:
            // `.medium` is already Gemini 2.5's default, so this pins today's cost rather than
            // lowering it. Set explicitly because the families default differently — Gemini 3
            // defaults to `.high`, roughly 4x the image tokens — so pinning keeps this demo's cost
            // the same if the model changes. Summarizing a scene does not need that detail; raise it
            // for OCR. Foundation Models has no equivalent setting: each model sizes images itself.
            let provider = RTSLLMProvider.gemini(
                modelIDString: RTSGeminiModelID.gemini25Flash.modelIDString,
                options: RTSGeminiOptions(mediaResolution: .medium)
            )
            return (provider, RTSLLMGateway(apiKeys: [.gemini: apiKey]))
        case .appleAI:
            return (.appleAI, RTSLLMGateway(apiKeys: [:]))
        #if OS27
        case .claudeFoundationModels:
            let claude = ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey(apiKey))
            let languageModel = RTSFoundationLanguageModel(
                claude,
                kind: .anthropic,
                modelID: RTSAnthropicModelID.claudeSonnet46.modelIDString
            )
            return (.foundationModel(languageModel), RTSLLMGateway(apiKeys: [:]))
        #endif
        }
    }

    /// Re-encodes arbitrary image bytes to JPEG so any album format (HEIC, PNG, …) is sent as a
    /// provider-friendly `image/jpeg`.
    private static func jpegData(from data: Data) -> Data? {
        #if canImport(UIKit)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.9)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        #else
        return nil
        #endif
    }
}
