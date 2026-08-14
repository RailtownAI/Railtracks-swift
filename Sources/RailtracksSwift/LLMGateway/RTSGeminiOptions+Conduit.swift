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
    /// The Conduit enum this maps onto. Kept as an explicit switch rather than a shared raw value so a
    /// new case on either side fails to compile here instead of silently dropping out of the request.
    var conduitValue: GeminiOptions.MediaResolution {
        switch self {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .ultraHigh:
            return .ultraHigh
        }
    }
}

extension RTSGeminiOptions {
    /// Writes these settings onto a Conduit `GenerateConfig`, preserving whatever the caller already
    /// configured. Gemini owns the `GeminiOptions` payload, so this reads the existing value back
    /// before writing rather than replacing it wholesale.
    func applyToConduitConfig(_ config: inout GenerateConfig) {
        guard let mediaResolution else {
            return
        }
        var geminiOptions: GeminiOptions = config[custom: GeminiProvider.self] ?? GeminiOptions()
        geminiOptions.mediaResolution = mediaResolution.conduitValue
        config[custom: GeminiProvider.self] = geminiOptions
    }
}

//
// MARK: - validation
//

extension RTSGeminiOptions {
    /// Model identifiers known to reject `.ultraHigh`. Google exposes the level on Gemini 3, but the
    /// `v1beta` endpoint rejects it outright for Flash — a 400, not a silent downgrade.
    private static let modelsRejectingUltraHigh = ["gemini-3-flash"]

    /// Warns about settings this model will ignore or reject, at session-build time — before the
    /// request is assembled, so the developer sees it on the run that introduced the mistake.
    ///
    /// This is the seam the type system cannot cover: `RTSGeminiOptions` is attached to the provider,
    /// but support for each setting varies by *model* within Gemini, and `modelIDString` is a free
    /// string. Logs first, then escalates through a replaceable reporter so a DEBUG build traps while
    /// a shipped app only warns — degrading beats trapping on a user's device.
    static func warnAboutUnsupportedSettings(
        _ options: RTSGeminiOptions,
        modelIDString: String,
        agentName: String
    ) {
        guard let mediaResolution = options.mediaResolution else {
            return
        }
        // Gemini 3 is the first family to accept the parameter; earlier ones charge a flat per-image
        // rate that nothing in the request can change.
        if !modelIDString.hasPrefix("gemini-3") {
            report("""
                ⚠️ [\(agentName)] mediaResolution '\(mediaResolution.rawValue)' is set, but model \
                '\(modelIDString)' does not support it — Gemini applies the parameter from Gemini 3 \
                onward. The setting will be ignored and images will cost the model's flat per-image \
                rate. Either move to a Gemini 3 model or drop the setting.
                """)
            return
        }
        if mediaResolution == .ultraHigh,
           Self.modelsRejectingUltraHigh.contains(where: { modelIDString.hasPrefix($0) }) {
            report("""
                ⚠️ [\(agentName)] mediaResolution '.ultraHigh' is not accepted by model \
                '\(modelIDString)' and the request will fail with HTTP 400. Use '.high' on Flash, or \
                switch to a Pro model.
                """)
        }
    }

    /// How a detected problem is escalated after it has been logged. Defaults to `assertionFailure`,
    /// which traps in a DEBUG build and is compiled out of a release one.
    ///
    /// Exists as a seam for the library's own tests: asserting on these messages would otherwise abort
    /// the test run, leaving the one diagnostic meant to be impossible to miss as the only behavior
    /// here with no coverage. Not synchronized, and nothing outside the tests should assign it —
    /// production only reads it, and the suite that swaps it is `.serialized`.
    nonisolated(unsafe) static var reportUnsupportedSetting: @Sendable (String) -> Void = { message in
        assertionFailure(message)
    }

    private static func report(_ message: String) {
        log.warning("\(message)")
        reportUnsupportedSetting(message)
    }
}
