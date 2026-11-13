//
//  AppleAIImageDecodingTests.swift
//  RailtracksSwiftTests
//
//  Foundation Models takes images as decoded pixels, not bytes, so the FoundationModels path decodes
//  each `RTSImage` with ImageIO before attaching it. These tests pin that decode: the pixels, the EXIF
//  orientation kept alongside them, and the error for bytes that are not an image.
//  See docs/foundation-models-image-input.md.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite("AppleAI image decoding")
struct AppleAIImageDecodingTests {

    @Test("A PNG decodes to its pixel size, upright")
    func decodesPNG() throws {
        let data = try Self.encodedImage(width: 4, height: 3, type: .png)
        let image = RTSImage(data: data, mimeType: "image/png")

        let decoded = try image.decodedForFoundationModels(index: 0)

        #expect(decoded.cgImage.width == 4)
        #expect(decoded.cgImage.height == 3)
        #expect(decoded.orientation == .up)
    }

    @Test("A JPEG decodes to its pixel size")
    func decodesJPEG() throws {
        let data = try Self.encodedImage(width: 5, height: 2, type: .jpeg)
        let image = RTSImage(data: data, mimeType: "image/jpeg")

        let decoded = try image.decodedForFoundationModels(index: 0)

        #expect(decoded.cgImage.width == 5)
        #expect(decoded.cgImage.height == 2)
    }

    @Test("EXIF orientation is read from the source, not baked into the pixels")
    func readsOrientation() throws {
        // 6 is "rotate 90° clockwise to display", how a phone stores a portrait photo.
        let data = try Self.encodedImage(width: 6, height: 4, type: .jpeg, orientation: 6)
        let image = RTSImage(data: data, mimeType: "image/jpeg")

        let decoded = try image.decodedForFoundationModels(index: 0)

        #expect(decoded.orientation == .right)
        #expect(decoded.cgImage.width == 6)
        #expect(decoded.cgImage.height == 4)
    }

    @Test("The MIME type is not needed: ImageIO sniffs the bytes")
    func ignoresMIMEType() throws {
        let data = try Self.encodedImage(width: 2, height: 2, type: .png)
        let image = RTSImage(data: data, mimeType: "application/octet-stream")

        let decoded = try image.decodedForFoundationModels(index: 0)

        #expect(decoded.cgImage.width == 2)
    }

    @Test("Bytes that are not an image fail with decodingFailed naming the image")
    func rejectsGarbage() throws {
        let image = RTSImage(data: Data("not an image".utf8), mimeType: "image/png")

        let error = try #require(throws: RTSError.self) {
            try image.decodedForFoundationModels(index: 2)
        }

        guard case .decodingFailed(let detail, _) = error else {
            Issue.record("expected decodingFailed, got \(error)")
            return
        }
        #expect(detail?.contains("image 2") == true)
        #expect(detail?.contains("image/png") == true)
    }

    @Test("Empty data fails with decodingFailed")
    func rejectsEmptyData() throws {
        let image = RTSImage(data: Data(), mimeType: "image/jpeg")

        let error = try #require(throws: RTSError.self) {
            try image.decodedForFoundationModels(index: 0)
        }

        guard case .decodingFailed = error else {
            Issue.record("expected decodingFailed, got \(error)")
            return
        }
    }

    #if canImport(FoundationModels) && compiler(>=6.4)
    @Test("A decodable image builds an attachment on OS 27")
    func buildsAttachment() throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let data = try Self.encodedImage(width: 2, height: 2, type: .png)
        let image = RTSImage(data: data, mimeType: "image/png")

        // `Attachment` is opaque; reaching it without throwing is what this pins.
        _ = try image.foundationModelsAttachment(index: 0)
    }
    #endif

    // MARK: - Fixtures

    /// Draws a solid red image and encodes it, optionally tagged with an EXIF orientation.
    /// Shared with `AppleAIImageDeliveryTests`.
    static func encodedImage(
        width: Int,
        height: Int,
        type: UTType,
        orientation: UInt32? = nil
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
