//
//  VisionViewModel.swift
//  RailtracksSwiftDemo
//

import Foundation
import RailtracksSwift
import Logging
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Vision demo: pick a photo, then ask a Gemini vision model to summarize it. Demonstrates
/// multimodal input — an `RTSImage` attached to the prompt via `flow.run(agent:prompt:images:)`.
@Observable
class VisionViewModel {
    let prompt: String = "Summarize what is shown in this image in a few sentences."
    /// Picked photo, normalized to JPEG for consistent provider support and display.
    var pickedImageData: Data?
    var promptResult: String = ""
    var isRunning = false
    var isShowingKeyPrompt = false

    /// Normalize picked photo data (which may be HEIC/PNG/…) to JPEG.
    func setPickedImage(_ data: Data) {
        pickedImageData = Self.jpegData(from: data) ?? data
        promptResult = ""
    }

    func startPrompt() {
        guard let apiKey = KeychainHelper.readGeminiKey() else {
            isShowingKeyPrompt = true
            return
        }
        guard let imageData = pickedImageData else {
            return
        }
        isRunning = true
        promptResult = ""
        let prompt = self.prompt
        Task { [weak self] in
            defer { self?.isRunning = false }
            let gateway = RTSLLMGateway(apiKeys: [.gemini: apiKey])
            let flow = RTSFlow(title: "Image Summary")
            let agent = RTSAgent(
                llmProvider: .gemini(modelIDString: RTSGeminiModelID.gemini25Flash.modelIDString),
                name: "Image Summarizer",
                systemMessage: "You are a helpful assistant that describes and summarizes images."
            )
            let image = RTSImage(data: imageData, mimeType: "image/jpeg")
            Log.debug("🖼️ starting image summary...")
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
