//
//  GeminiOptionsTests.swift
//  RailtracksSwiftTests
//
//  Covers the provider-specific settings path: Gemini-only options ride in the `.gemini` case's
//  associated value, reach Conduit's `GenerateConfig`, and are reported when the chosen model cannot
//  honor them.
//

import Testing
import Foundation
import Conduit
@testable import RailtracksSwift

/// Accumulates the diagnostics `RTSGeminiOptions.reportUnsupportedSetting` would otherwise send to
/// `assertionFailure`. `@unchecked Sendable` is sound here: the reporter is invoked synchronously on
/// the calling thread, and the suite below is `.serialized`.
private final class SettingRecorder: @unchecked Sendable {
    var messages: [String] = []
}

/// Runs `body` with the reporter swapped for a collector, and returns everything it reported. Without
/// this the calls below would trap in a DEBUG build and abort the test run — which is the behavior
/// under test, so it has to be observed rather than triggered.
private func recordingWarnings(during body: () -> Void) -> [String] {
    let recorder = SettingRecorder()
    let previous = RTSGeminiOptions.reportUnsupportedSetting
    RTSGeminiOptions.reportUnsupportedSetting = { message in
        recorder.messages.append(message)
    }
    defer {
        RTSGeminiOptions.reportUnsupportedSetting = previous
    }
    body()
    return recorder.messages
}

/// `.serialized` because the validation tests swap `RTSGeminiOptions.reportUnsupportedSetting`, a
/// process-wide `nonisolated(unsafe)` seam that would race if these ran concurrently.
@Suite("Gemini provider options", .serialized)
struct GeminiOptionsTests {

    // MARK: - Conduit mapping

    @Test("Media resolution reaches Conduit's Gemini options")
    func mediaResolutionReachesConduit() throws {
        var config = GenerateConfig.default
        RTSGeminiOptions(mediaResolution: .low).applyToConduitConfig(&config)

        let geminiOptions: GeminiOptions = try #require(config[custom: GeminiProvider.self])
        #expect(geminiOptions.mediaResolution == .low)
    }

    @Test("Every case maps onto a Conduit counterpart")
    func everyCaseMaps() {
        let expected: [RTSGeminiMediaResolution: GeminiOptions.MediaResolution] = [
            .low: .low,
            .medium: .medium,
            .high: .high,
            .ultraHigh: .ultraHigh,
        ]
        for (rtsValue, conduitValue) in expected {
            #expect(rtsValue.conduitValue == conduitValue)
        }
    }

    @Test("An unset media resolution writes nothing at all")
    func unsetWritesNothing() {
        // Absent must stay absent rather than becoming an explicit level — the model default is the
        // provider's business, and writing one would silently pin it.
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

    // MARK: - validation

    @Test("A pre-Gemini-3 model warns that the setting is ignored")
    func preGemini3ModelWarns() throws {
        let reported = recordingWarnings {
            RTSGeminiOptions.warnAboutUnsupportedSettings(
                RTSGeminiOptions(mediaResolution: .low),
                modelIDString: "gemini-2.5-flash",
                agentName: "Image Summarizer"
            )
        }

        let message = try #require(reported.first)
        #expect(reported.count == 1)
        // Actionable without reading the library: which agent, which model, what happens instead.
        #expect(message.contains("Image Summarizer"))
        #expect(message.contains("gemini-2.5-flash"))
        #expect(message.contains("ignored"))
    }

    @Test("ultraHigh on Flash warns about the 400 it would cause")
    func ultraHighOnFlashWarns() throws {
        let reported = recordingWarnings {
            RTSGeminiOptions.warnAboutUnsupportedSettings(
                RTSGeminiOptions(mediaResolution: .ultraHigh),
                modelIDString: "gemini-3-flash-preview",
                agentName: "Image Summarizer"
            )
        }

        let message = try #require(reported.first)
        #expect(message.contains("ultraHigh"))
        #expect(message.contains("400"))
    }

    @Test("A supported combination warns about nothing")
    func supportedCombinationIsQuiet() {
        let reported = recordingWarnings {
            RTSGeminiOptions.warnAboutUnsupportedSettings(
                RTSGeminiOptions(mediaResolution: .high),
                modelIDString: "gemini-3-flash-preview",
                agentName: "Image Summarizer"
            )
        }
        #expect(reported.isEmpty)
    }

    @Test("ultraHigh on Pro is allowed through")
    func ultraHighOnProIsQuiet() {
        // Only Flash is known to reject it; warning on Pro would train developers to ignore this.
        let reported = recordingWarnings {
            RTSGeminiOptions.warnAboutUnsupportedSettings(
                RTSGeminiOptions(mediaResolution: .ultraHigh),
                modelIDString: "gemini-3-pro-preview",
                agentName: "Image Summarizer"
            )
        }
        #expect(reported.isEmpty)
    }

    @Test("No media resolution means no validation noise on any model")
    func unsetNeverWarns() {
        for model in ["gemini-2.5-flash", "gemini-1.5-pro", "gemini-3-flash-preview"] {
            let reported = recordingWarnings {
                RTSGeminiOptions.warnAboutUnsupportedSettings(
                    RTSGeminiOptions(),
                    modelIDString: model,
                    agentName: "Image Summarizer"
                )
            }
            #expect(reported.isEmpty, "'\(model)' warned with no setting applied")
        }
    }
}
