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
        let normalized = Self.jpegData(from: data) ?? data
        Self.logDimensions(original: data, normalized: normalized)
        pickedImageData = normalized
        promptResult = ""
    }

    /// Logs the pixel dimensions on both sides of the JPEG re-encode.
    ///
    /// Gemini charges 258 tokens for an image no larger than 384px in either dimension, and tiles
    /// anything bigger into 768×768 tiles at 258 tokens each — so a large photo cannot cost less than
    /// four tiles. An observed 258 therefore means the model received a sub-384px image, and these two
    /// lines say whether it arrived that way or whether `jpegData(from:)` shrank it.
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
