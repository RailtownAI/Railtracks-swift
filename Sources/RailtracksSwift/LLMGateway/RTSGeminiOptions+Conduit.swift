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
    /// Writes these settings onto a Conduit `GenerateConfig`, preserving whatever the caller already
    /// configured. Gemini owns the `GeminiOptions` payload as one custom-options slot, so this reads
    /// the existing value back before writing rather than replacing it wholesale.
    func applyToConduitConfig(_ config: inout GenerateConfig) {
        guard let mediaResolution else {
            return
        }
        var geminiOptions: GeminiOptions = config[custom: GeminiProvider.self] ?? GeminiOptions()
        geminiOptions.mediaResolution = mediaResolution.conduitValue
        config[custom: GeminiProvider.self] = geminiOptions
    }
}
