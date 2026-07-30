//
//  RTSImage.swift
//  RailtracksSwift
//

import Foundation

/// An image attached to an agent prompt for multimodal (vision) input.
///
/// Holds the base64-encoded bytes for the provider, plus a lightweight source descriptor
/// (`sourceType` / `sourceInfo`) used for the redacted trace representation — the base64 payload is
/// **never** serialized into the run report (see `RTSValue.image` encoding).
///
/// The bytes are read eagerly at construction (a snapshot), so the image is immune to the source file
/// moving or being deleted before the async LLM call, is source-agnostic (file, camera, pasteboard,
/// network, generated), and is trivially `Sendable`.
public struct RTSImage: Sendable, Equatable {
    /// Base64-encoded image bytes, sent to the provider.
    public let base64Data: String
    /// MIME type, e.g. `"image/png"`.
    public let mimeType: String
    /// Source kind for the trace descriptor: `"local"`, `"url"`, or `"data_uri"`.
    public let sourceType: String
    /// Source reference for the trace `info` field: a file path / URL, or `"..."` for raw in-memory data.
    public let sourceInfo: String

    /// Creates an image from raw bytes (e.g. camera, pasteboard, generated). Traced as `data_uri`.
    public init(data: Data, mimeType: String) {
        self.base64Data = data.base64EncodedString()
        self.mimeType = mimeType
        self.sourceType = "data_uri"
        self.sourceInfo = "..."
    }

    /// Creates an image by reading a URL's bytes immediately (eager snapshot). MIME is inferred from the
    /// path extension. File URLs are traced as `local` (path in `info`); other URLs as `url`.
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        self.base64Data = data.base64EncodedString()
        self.mimeType = Self.mimeType(forPathExtension: url.pathExtension)
        if url.isFileURL {
            self.sourceType = "local"
            self.sourceInfo = url.path
        } else {
            self.sourceType = "url"
            self.sourceInfo = url.absoluteString
        }
    }

    private static func mimeType(forPathExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        default:
            return "application/octet-stream"
        }
    }
}
