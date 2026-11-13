//
//  AppleAIImageDeliveryTests.swift
//  RailtracksSwiftTests
//
//  What the FoundationModels path does with an agent's images: attach them (OS 27, a model with
//  vision), drop them with a warning (below OS 27), or fail before sending (a model without vision).
//  The decision is a pure function of the platform and the model's capabilities, so it is pinned
//  here without a model. See docs/foundation-models-image-input.md.
//

import Testing
import Foundation
@testable import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite("AppleAI image delivery")
struct AppleAIImageDeliveryTests {

    @Test("No images: text only, whatever the platform or model")
    func noImages() throws {
        for platformSupportsImages in [true, false] {
            for modelSupportsVision in [true, false] {
                let delivery = try RTSAppleAIImageDelivery.decide(
                    imageCount: 0,
                    platformSupportsImages: platformSupportsImages,
                    modelSupportsVision: modelSupportsVision,
                    modelDescription: "model"
                )
                #expect(delivery == .textOnly)
            }
        }
    }

    @Test("Images on a platform without image input are dropped, not an error")
    func belowOS27() throws {
        // A model below OS 27 never reports vision, so both values must give the same answer.
        for modelSupportsVision in [true, false] {
            let delivery = try RTSAppleAIImageDelivery.decide(
                imageCount: 2,
                platformSupportsImages: false,
                modelSupportsVision: modelSupportsVision,
                modelDescription: "model"
            )
            #expect(delivery == .dropped)
        }
    }

    @Test("Images on a vision model are attached")
    func visionModel() throws {
        let delivery = try RTSAppleAIImageDelivery.decide(
            imageCount: 1,
            platformSupportsImages: true,
            modelSupportsVision: true,
            modelDescription: "model"
        )
        #expect(delivery == .attached)
    }

    @Test("Images on a model without vision fail with invalidInvocation naming the model")
    func modelWithoutVision() throws {
        let error = try #require(throws: RTSError.self) {
            try RTSAppleAIImageDelivery.decide(
                imageCount: 1,
                platformSupportsImages: true,
                modelSupportsVision: false,
                modelDescription: "FoundationModels-Anthropic-text-only"
            )
        }
        guard case .invalidInvocation(let detail, _) = error else {
            Issue.record("expected invalidInvocation, got \(error)")
            return
        }
        #expect(detail.contains("FoundationModels-Anthropic-text-only"))
        #expect(detail.contains("image"))
    }

    #if canImport(FoundationModels) && compiler(>=6.4)
    @Test("Vision support is read from the model's capabilities")
    func readsCapabilities() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        #expect(RTSAppleAIImageDelivery.supportsVision(LanguageModelCapabilities([.vision, .toolCalling])))
        #expect(!RTSAppleAIImageDelivery.supportsVision(LanguageModelCapabilities([.toolCalling])))
        #expect(!RTSAppleAIImageDelivery.supportsVision(LanguageModelCapabilities([])))
    }

    @Test("The platform supports image input on OS 27")
    func platformSupport() {
        guard #available(macOS 27, iOS 27, *) else {
            #expect(!RTSAppleAIImageDelivery.platformSupportsImages)
            return
        }
        #expect(RTSAppleAIImageDelivery.platformSupportsImages)
    }

    /// Live: an `.appleAI` session sends an image to the on-device model. The model's answer is not
    /// asserted, since its wording is not stable; that it answers, rather than throwing, is the point.
    /// A system model without vision must instead fail before sending.
    @Test("A live on-device run accepts an image")
    func liveSystemModelRun() async throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        guard case .available = SystemLanguageModel.default.availability else {
            print("⏭️ on-device model unavailable; skipping live image run")
            return
        }
        let data = try AppleAIImageDecodingTests.encodedImage(width: 64, height: 64, type: .png)
        let image = RTSImage(data: data, mimeType: "image/png")
        let agent = RTSAgent(llmProvider: .appleAI, name: "Image Probe")
        let gateway = RTSLLMGateway(apiKeys: [:])
        let invoker = RTSNodeInvoker(sessionID: UUID())
        let session = try gateway.session(invoker: invoker, agentNode: agent)
        let prompt = "What colour is this image? Answer in one word."

        guard AppleAISession.systemModelSupportsVision else {
            await #expect(throws: RTSError.self) {
                try await session.run(prompt, images: [image], runID: UUID())
            }
            print("ℹ️ system model reports no vision; image run correctly refused")
            return
        }
        let answer = try await session.run(prompt, images: [image], runID: UUID())

        #expect(!answer.isEmpty)
        print("ℹ️ live image run answered: \(answer)")
    }

    // MARK: - Failures before the call

    /// A failure before `respond` (no vision, an undecodable image) records the prompt it would
    /// have sent, as a failed `respond` does. Without it, whether the failure reached `llm.failure`
    /// would depend on whether the agent happened to have a system message already in the log.
    @Test("A model without vision records the unsent prompt, images included")
    func noVisionRecordsPrompt() async throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let session = try Self.appleAISession(supportsVision: false)
        let data = try AppleAIImageDecodingTests.encodedImage(width: 2, height: 2, type: .png)
        let image = RTSImage(data: data, mimeType: "image/png")

        await #expect(throws: RTSError.self) {
            try await session.send("Describe this", images: [image, image])
        }

        Self.expectRecordedPrompt(session.messages(), text: "Describe this", imageCount: 2)
    }

    @Test("An undecodable image records the unsent prompt, images included")
    func undecodableImageRecordsPrompt() async throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let session = try Self.appleAISession(supportsVision: true)
        let image = RTSImage(data: Data("not an image".utf8), mimeType: "image/png")

        await #expect(throws: RTSError.self) {
            try await session.send("Describe this", images: [image])
        }

        Self.expectRecordedPrompt(session.messages(), text: "Describe this", imageCount: 1)
    }

    /// A session on the system model with no tools or instructions, so the only message a failed
    /// send can leave is the prompt it records. Nothing here reaches the model.
    @available(macOS 27, iOS 27, *)
    private static func appleAISession(supportsVision: Bool) throws -> AppleAISession {
        let agent = RTSAgent(llmProvider: .appleAI, name: "Image Failure Probe")
        let (session, _) = try AppleAISession.build(
            fromAgentTools: [],
            invoker: RTSNodeInvoker(sessionID: UUID()),
            createdBy: agent,
            makeSubSession: { _ in
                throw RTSError.providerUnavailable("no sub-agents in this test")
            },
            supportsVision: supportsVision
        )
        return session
    }

    private static func expectRecordedPrompt(
        _ messages: [RTSMessage],
        text: String,
        imageCount: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(messages.count == 1, sourceLocation: sourceLocation)
        guard let message = messages.last, message.role == .user else {
            Issue.record(
                "expected one user message, got \(messages)",
                sourceLocation: sourceLocation
            )
            return
        }
        guard case .parts(let parts) = message.content else {
            Issue.record("expected .parts, got \(message.content)", sourceLocation: sourceLocation)
            return
        }
        #expect(parts.count == 1 + imageCount, sourceLocation: sourceLocation)
        guard case .text(let recordedText)? = parts.first else {
            Issue.record("expected the text first, got \(parts)", sourceLocation: sourceLocation)
            return
        }
        #expect(recordedText == text, sourceLocation: sourceLocation)
        for part in parts.dropFirst() {
            guard case .image(let image) = part else {
                Issue.record("expected an image part, got \(part)", sourceLocation: sourceLocation)
                continue
            }
            #expect(image.info == "...", sourceLocation: sourceLocation)
        }
    }
    #endif
}
