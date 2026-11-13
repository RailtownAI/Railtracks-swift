//
//  AppleAIImageTraceTests.swift
//  RailtracksSwiftTests
//
//  How an image sent on the FoundationModels path appears in the messages the `llm.*` events, and
//  through them the trace, are built from: as the same redacted `{modality:"image", type:"data_uri",
//  info:"..."}` part the Conduit path writes, never as pixels. See docs/foundation-models-image-input.md.
//

import Testing
import Foundation
@testable import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite("AppleAI image tracing")
struct AppleAIImageTraceTests {

    // MARK: - What a failed send records

    @Test("A failed send without images records its prompt as text")
    func failedSendTextOnly() {
        let content = RTSMessage.Content.sentPrompt("Describe this", attachedImageCount: 0)

        guard case .text(let text) = content else {
            Issue.record("expected .text, got \(content)")
            return
        }
        #expect(text == "Describe this")
    }

    @Test("A failed send with images records the text, then one redacted image part per image")
    func failedSendWithImages() {
        let content = RTSMessage.Content.sentPrompt("Describe this", attachedImageCount: 2)

        guard case .parts(let parts) = content else {
            Issue.record("expected .parts, got \(content)")
            return
        }
        #expect(parts.count == 3)
        Self.expectText(parts[0], "Describe this")
        Self.expectRedactedImage(parts[1])
        Self.expectRedactedImage(parts[2])
    }

    @Test("The redacted image part encodes as Python's descriptor")
    func redactedImageEncoding() throws {
        let content = RTSMessage.Content.sentPrompt("hi", attachedImageCount: 1)

        let json = try String(decoding: JSONEncoder().encode(content), as: UTF8.self)

        #expect(json.contains("\"modality\":\"image\""))
        #expect(json.contains("\"type\":\"data_uri\""))
        #expect(json.contains("\"info\":\"...\""))
        #expect(!json.contains("base64"))
    }

    #if canImport(FoundationModels) && compiler(>=6.4)
    // MARK: - Transcript entries

    @Test("A prompt entry with attachments becomes text and image parts, in segment order")
    func promptWithAttachments() throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let attachment = try Self.attachmentSegment()
        let entry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [
                .text(.init(content: "What is this?")),
                .attachment(attachment),
                .attachment(attachment),
            ])
        )

        let message = try #require(entry.toRTSMessage())

        #expect(message.role == .user)
        guard case .parts(let parts) = message.content else {
            Issue.record("expected .parts, got \(message.content)")
            return
        }
        #expect(parts.count == 3)
        Self.expectText(parts[0], "What is this?")
        Self.expectRedactedImage(parts[1])
        Self.expectRedactedImage(parts[2])
    }

    @Test("A prompt entry without attachments stays plain text")
    func promptWithoutAttachments() throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let entry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(.init(content: "hi")), .text(.init(content: "there"))])
        )

        let message = try #require(entry.toRTSMessage())

        guard case .text(let text) = message.content else {
            Issue.record("expected .text, got \(message.content)")
            return
        }
        #expect(text == "hi there")
    }

    /// Live: after a real image run, the session's messages hold the prompt as text plus an image
    /// part, which shows the transcript keeps the attachment and the mapping reads it.
    @Test("A live on-device image run records an image part on its prompt")
    func liveRunRecordsImagePart() async throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        guard case .available = SystemLanguageModel.default.availability,
              AppleAISession.systemModelSupportsVision else {
            print("⏭️ on-device vision model unavailable; skipping live image trace check")
            return
        }
        let data = try AppleAIImageDecodingTests.encodedImage(width: 64, height: 64, type: .png)
        let image = RTSImage(data: data, mimeType: "image/png")
        let agent = RTSAgent(llmProvider: .appleAI, name: "Image Trace Probe")
        let gateway = RTSLLMGateway(apiKeys: [:])
        let invoker = RTSNodeInvoker(sessionID: UUID())
        let session = try gateway.session(invoker: invoker, agentNode: agent)

        _ = try await session.run("What colour is this image? One word.", images: [image], runID: UUID())

        let userMessage = try #require(session.messages().first { $0.role == .user })
        guard case .parts(let parts) = userMessage.content else {
            Issue.record("expected .parts, got \(userMessage.content)")
            return
        }
        #expect(parts.count == 2)
        Self.expectText(parts[0], "What colour is this image? One word.")
        Self.expectRedactedImage(parts[1])
    }

    @available(macOS 27, iOS 27, *)
    private static func attachmentSegment() throws -> Transcript.AttachmentSegment {
        let data = try AppleAIImageDecodingTests.encodedImage(width: 2, height: 2, type: .png)
        let decoded = try RTSImage(data: data, mimeType: "image/png").decodedForFoundationModels(index: 0)
        return Transcript.AttachmentSegment(
            content: .image(Transcript.ImageAttachment(decoded.cgImage, orientation: decoded.orientation))
        )
    }
    #endif

    // MARK: - Helpers

    private static func expectText(
        _ part: RTSMessage.ContentPart,
        _ expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .text(let text) = part else {
            Issue.record("expected a text part, got \(part)", sourceLocation: sourceLocation)
            return
        }
        #expect(text == expected, sourceLocation: sourceLocation)
    }

    private static func expectRedactedImage(
        _ part: RTSMessage.ContentPart,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .image(let image) = part else {
            Issue.record("expected an image part, got \(part)", sourceLocation: sourceLocation)
            return
        }
        #expect(image.type == "data_uri", sourceLocation: sourceLocation)
        #expect(image.info == "...", sourceLocation: sourceLocation)
    }
}
