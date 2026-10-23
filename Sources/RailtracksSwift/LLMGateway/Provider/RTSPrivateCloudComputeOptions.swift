//
//  RTSPrivateCloudComputeOptions.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-10-23.
//

import Foundation

/// How much the Private Cloud Compute model reasons before it answers.
///
/// Reasoning is extra text the model generates, so it uses tokens, and those count toward the
/// model's 32,768-token context. Only Private Cloud Compute offers this; the on-device model does
/// not. Apple's API also has a `custom(String)` level, deliberately not offered here until there
/// is a documented value to pass.
public enum RTSPrivateCloudComputeReasoningLevel: String, Sendable, Equatable {
    case light
    case moderate
    case deep
}

/// Settings that exist only on Private Cloud Compute.
///
/// These live in the `.privateCloudCompute` case's associated value, as `RTSGeminiOptions` live in
/// `.gemini`'s, so that moving an agent to another provider discards them *by construction*
/// rather than leaving a setting that silently does nothing.
public struct RTSPrivateCloudComputeOptions: Sendable, Equatable {
    /// How much the model reasons before answering. `nil` leaves the model default in place.
    public var reasoningLevel: RTSPrivateCloudComputeReasoningLevel?

    public init(reasoningLevel: RTSPrivateCloudComputeReasoningLevel? = nil) {
        self.reasoningLevel = reasoningLevel
    }
}
