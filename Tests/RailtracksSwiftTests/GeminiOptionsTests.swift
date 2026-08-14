//
//  GeminiOptionsTests.swift
//  RailtracksSwiftTests
//
//  Covers the provider-specific settings path: Gemini-only options ride in the `.gemini` case's
//  associated value and reach Conduit's `GenerateConfig` without disturbing what else is configured
//  there.
//

import Testing
import Foundation
import Conduit
@testable import RailtracksSwift

@Suite("Gemini provider options")
struct GeminiOptionsTests {

    // MARK: - Conduit mapping

    @Test("Media resolution reaches Conduit's Gemini options")
    func mediaResolutionReachesConduit() throws {
        var config = GenerateConfig.default
        RTSGeminiOptions(mediaResolution: .low).applyToConduitConfig(&config)

        let geminiOptions: GeminiOptions = try #require(config[custom: GeminiProvider.self])
        #expect(geminiOptions.mediaResolution == .low)
    }

    @Test("Every exposed case maps onto a Conduit counterpart")
    func everyCaseMaps() {
        let expected: [RTSGeminiMediaResolution: GeminiOptions.MediaResolution] = [
            .low: .low,
            .medium: .medium,
            .high: .high,
        ]
        for (rtsValue, conduitValue) in expected {
            #expect(rtsValue.conduitValue == conduitValue)
        }
    }

    @Test("ultraHigh is withheld from library consumers")
    func ultraHighIsNotExposed() {
        // Conduit carries `.ultraHigh` so the value stays reachable if Google enables it, but v1beta
        // rejects it with HTTP 400 on every Gemini model, so RailtracksSwift does not offer it. If a
        // case named this ever appears, `conduitValue` must be revisited before it ships.
        #expect(RTSGeminiMediaResolution(rawValue: "ultraHigh") == nil)
    }

    @Test("An unset media resolution writes nothing at all")
    func unsetWritesNothing() {
        // Absent must stay absent rather than becoming an explicit level — the model default is the
        // provider's business, and writing one would silently pin it. The two families default
        // differently (3.x to high, 2.5 to medium), so pinning would change cost on a model swap.
        var config = GenerateConfig.default
        RTSGeminiOptions().applyToConduitConfig(&config)
        let geminiOptions: GeminiOptions? = config[custom: GeminiProvider.self]
        #expect(geminiOptions == nil)
    }

    @Test("Applying preserves Gemini options the caller already set")
    func applyingPreservesExistingOptions() throws {
        // The whole `GeminiOptions` payload is one custom-options slot, so a naive write would
        // clobber a thinkingConfig set elsewhere.
        var config = GenerateConfig.default
        config[custom: GeminiProvider.self] = GeminiOptions(thinkingConfig: ["thinkingLevel": "low"])
        RTSGeminiOptions(mediaResolution: .high).applyToConduitConfig(&config)

        let geminiOptions: GeminiOptions = try #require(config[custom: GeminiProvider.self])
        #expect(geminiOptions.mediaResolution == .high)
        #expect(geminiOptions.thinkingConfig?["thinkingLevel"] == "low")
    }

    // MARK: - provider case

    @Test("Options default to empty, so existing call sites are unaffected")
    func optionsAreDefaulted() {
        let provider = RTSLLMProvider.gemini(modelIDString: "gemini-3-flash-preview")
        guard case .gemini(let modelIDString, let options) = provider else {
            Issue.record("expected a gemini provider")
            return
        }
        #expect(modelIDString == "gemini-3-flash-preview")
        #expect(options.mediaResolution == nil)
    }

    @Test("Model ID and description ignore the options payload")
    func modelIdentityUnaffectedByOptions() {
        let provider = RTSLLMProvider.gemini(
            modelIDString: "gemini-3-flash-preview",
            options: RTSGeminiOptions(mediaResolution: .low)
        )
        #expect(provider.modelID == "gemini-3-flash-preview")
        #expect(provider.description == "Gemini-gemini-3-flash-preview")
        #expect(provider.kind == .gemini)
    }
}
