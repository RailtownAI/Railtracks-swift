//
//  RTSImage+FoundationModels.swift
//  RailtracksSwift
//

import Foundation
import CoreGraphics
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

/// An `RTSImage` decoded for Foundation Models: its pixels, plus the EXIF orientation they are
/// meant to be shown at.
///
/// The orientation is kept beside the pixels rather than baked into them, so each model applies it
/// its own way. Without it, a portrait photo would reach the model sideways.
struct RTSDecodedImage {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation
}

extension RTSImage {
    /// Decodes the image's bytes with ImageIO.
    ///
    /// Foundation Models takes decoded pixels, not encoded bytes, so this is the step between an
    /// `RTSImage` and an `Attachment`. `mimeType` plays no part: ImageIO identifies the format from the
    /// bytes, so an image whose extension gave `application/octet-stream` still decodes.
    ///
    /// - Parameter index: the image's position in the prompt, used only to name it in the error.
    /// - Throws: `RTSError.decodingFailed` when the bytes are not an image ImageIO can read.
    func decodedForFoundationModels(index: Int) throws -> RTSDecodedImage {
        guard
            let data = Data(base64Encoded: base64Data),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RTSError.decodingFailed(
                "image \(index) (\(mimeType)) could not be decoded as an image"
            )
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = properties?[kCGImagePropertyOrientation] as? UInt32
        let orientation = rawOrientation.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return RTSDecodedImage(cgImage: cgImage, orientation: orientation)
    }
}

/// What the FoundationModels path does with an agent's images.
///
/// A pure function of the platform and the model, so it is decided (and tested) apart from the
/// session that acts on it.
enum RTSAppleAIImageDelivery: Equatable {
    /// No images: the prompt is sent as text, exactly as before image support.
    case textOnly
    /// The images are attached to the prompt after its text.
    case attached
    /// Below OS 27 Foundation Models has no image input; the images are dropped with a warning
    /// and the text is sent. Not an error, so an agent sent the same images on every OS still runs.
    case dropped

    /// Decides how `imageCount` images are delivered.
    ///
    /// - Throws: `RTSError.invalidInvocation` when there are images, the platform can attach them,
    ///   and the model reports no `.vision` capability. Checked before sending, because the model's
    ///   own refusal would come only after the prompt went out and the transcript rolled back.
    static func decide(
        imageCount: Int,
        platformSupportsImages: Bool,
        modelSupportsVision: Bool,
        modelDescription: String
    ) throws -> RTSAppleAIImageDelivery {
        guard imageCount > 0 else {
            return .textOnly
        }
        guard platformSupportsImages else {
            return .dropped
        }
        guard modelSupportsVision else {
            throw RTSError.invalidInvocation(
                "\(modelDescription) does not support image input; \(imageCount) image(s) not sent"
            )
        }
        return .attached
    }

    /// Whether this OS, and the SDK the library was built with, can attach images to a prompt.
    static var platformSupportsImages: Bool {
        // XCODE26-SDK: `Attachment` exists only in the OS 27 SDK (Xcode 27, Swift 6.4).
        #if canImport(FoundationModels) && compiler(>=6.4)
        // OS26-FLOOR: image attachments are OS 27 API.
        if #available(macOS 27, iOS 27, *) {
            return true
        }
        #endif
        return false
    }
}

// XCODE26-SDK: `Attachment` and `LanguageModelCapabilities` exist only in the OS 27 SDK
// (Xcode 27, Swift 6.4).
#if canImport(FoundationModels) && compiler(>=6.4)
@available(macOS 27, iOS 27, *)
extension RTSAppleAIImageDelivery {
    /// Whether a model with these capabilities takes image input.
    static func supportsVision(_ capabilities: LanguageModelCapabilities) -> Bool {
        capabilities.contains(.vision)
    }
}

@available(macOS 27, iOS 27, *)
extension RTSImage {
    /// The image as a Foundation Models prompt attachment.
    ///
    /// Built from the decoded pixels rather than `Attachment(imageURL:)`: an `RTSImage` snapshots its
    /// bytes so it never depends on the source file still existing, and a `data_uri` image has no
    /// URL at all.
    ///
    /// - Throws: `RTSError.decodingFailed`, as `decodedForFoundationModels(index:)`.
    func foundationModelsAttachment(index: Int) throws -> Attachment<ImageAttachmentContent> {
        let decoded = try decodedForFoundationModels(index: index)
        return Attachment(decoded.cgImage, orientation: decoded.orientation)
    }
}
#endif
