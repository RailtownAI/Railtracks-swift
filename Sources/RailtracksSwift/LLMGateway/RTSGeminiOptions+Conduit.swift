//
//  RTSGeminiOptions+Conduit.swift
//  RailtracksSwift
//

import Foundation
import Conduit

//
// MARK: - Conduit mapping
//

extension RTSGeminiMediaResolution {
    /// The Conduit enum this maps onto.
    ///
    /// An explicit switch rather than a shared raw value, for two reasons: a new case on either side
    /// fails to compile here instead of silently dropping out of the request, and the two enums are
    /// deliberately *not* the same set — Conduit carries `.ultraHigh` to keep it reachable, while
    /// RailtracksSwift withholds it because `v1beta` rejects it on every Gemini model.
    var conduitValue: GeminiOptions.MediaResolution {
        switch self {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        }
    }
}

extension RTSGeminiOptions {
    /// The modalities `mediaResolution` is meaningful for.
    ///
    /// Declared beside the setting so the request pipeline never has to know what any individual
    /// Gemini option means. Video belongs here as much as image: Google defines the parameter as the
    /// budget allocated "per input image **or video frame**", so keying this off "does the request
    /// have an image" in the pipeline would already be wrong for a video request.
    private static let mediaResolutionModalities: RTSRequestModalities = [.image, .video]

    /// Writes these settings onto a Conduit `GenerateConfig` for a request carrying `modalities`,
    /// preserving whatever the caller already configured.
    ///
    /// Settings are withheld from requests they cannot affect — an agent that sets a media resolution
    /// and then sends a text-only turn puts nothing extra on that request. Gemini happens to ignore an
    /// irrelevant `mediaResolution` (verified: identical token counts, no error), but that is Gemini's
    /// behavior, not a guarantee any provider owes us.
    ///
    /// Gemini owns the `GeminiOptions` payload as one custom-options slot, so this reads the existing
    /// value back before writing rather than replacing it wholesale.
    func applyToConduitConfig(_ config: inout GenerateConfig, modalities: RTSRequestModalities) {
        guard
            let mediaResolution,
            !modalities.isDisjoint(with: Self.mediaResolutionModalities)
        else {
            return
        }
        var geminiOptions: GeminiOptions = config[custom: GeminiProvider.self] ?? GeminiOptions()
        geminiOptions.mediaResolution = mediaResolution.conduitValue
        config[custom: GeminiProvider.self] = geminiOptions
    }
}
