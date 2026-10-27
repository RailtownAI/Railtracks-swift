//
//  FoundationModelsErrorMapping.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-10-23.
//

import Foundation
import FoundationModels

/// Turns Foundation Models failures an app should act on into `RTSError` cases, so it can catch
/// them without importing FoundationModels or decoding an opaque error code.
///
/// Two today, both Private Cloud Compute: the user's daily limit (`quotaLimitReached`, with the
/// reset date) and the app's missing entitlement (`missingEntitlement`). Anything else has no
/// `RTSError` counterpart, and the caller rethrows it as it is. See
/// `docs/private-cloud-compute.md`.
enum FoundationModelsErrorMapping {

    static let privateCloudComputeEntitlement = "com.apple.developer.private-cloud-compute"

    /// The error a request fails with when the process lacks the PCC entitlement, measured on
    /// macOS 27 from an unsigned command-line program: a plain `NSError` nesting this one beneath
    /// two `FoundationModels.LanguageModelError` code -1 wrappers. Undocumented, so only trusted
    /// when the provider is Private Cloud Compute. A signed app lacking the entitlement never
    /// reaches this mapping: Apple stops it with a fatal error instead.
    static let missingEntitlementDomain = "ModelManagerServices.ModelManagerError"
    static let missingEntitlementCode = 1046

    /// How deep to search an error's underlying errors. The measured nesting is three; the limit
    /// only guards against a cycle.
    private static let maximumUnderlyingDepth = 8

    /// The user's Private Cloud Compute quota at one moment, in a type that needs no OS 27
    /// availability, so it can be injected in tests.
    struct QuotaState: Sendable, Equatable {
        var isLimitReached: Bool
        var resetDate: Date?
    }

    /// The `RTSError` an app should see instead of `error`, or `nil` when there is none and
    /// `error` should be rethrown as it is.
    ///
    /// - Parameters:
    ///   - error: What `respond` threw.
    ///   - provider: The agent's provider. Only Private Cloud Compute's kind enables the
    ///     entitlement and rate-limit mappings, whether chosen as `.privateCloudCompute` or wrapped
    ///     in `.foundationModel`.
    ///   - currentQuota: The quota right now. Read only when needed: to tell a rate limit from the
    ///     daily limit, and for a reset date the thrown error lacks. Injected so tests can control
    ///     it.
    static func rtsError(
        for error: Error,
        provider: RTSLLMProvider,
        currentQuota: () -> QuotaState = Self.privateCloudComputeQuota
    ) -> RTSError? {
        if let surfaced = errorFromToolCall(error) {
            return surfaced
        }
        let isPrivateCloudCompute = provider.kind == .privateCloudCompute
        // XCODE26-SDK: both error types exist only in the OS 27 SDK (Xcode 27, Swift 6.4).
        #if compiler(>=6.4)
        // OS26-FLOOR: both are OS 27 API, and nothing below OS 27 can throw them.
        if #available(macOS 27, iOS 27, *) {
            if let quotaError = error as? PrivateCloudComputeLanguageModel.Error,
               case .quotaLimitReached(let info) = quotaError {
                return RTSError.quotaLimitReached(
                    provider: provider.providerName,
                    resetDate: info.resetDate ?? currentQuota().resetDate
                )
            }
            if isPrivateCloudCompute,
               let modelError = error as? LanguageModelError,
               case .rateLimited(let info) = modelError {
                // A rate limit is the daily limit only when the quota says so. Otherwise it may
                // clear in seconds, and reporting it as the daily limit — with the daily reset
                // date, hours away — would have an app disable the feature until tomorrow.
                let quota = currentQuota()
                guard quota.isLimitReached else {
                    return nil
                }
                return RTSError.quotaLimitReached(
                    provider: provider.providerName,
                    resetDate: info.resetDate ?? quota.resetDate
                )
            }
        }
        #endif
        if isPrivateCloudCompute, hasMissingEntitlementError(error) {
            return RTSError.missingEntitlement(name: privateCloudComputeEntitlement)
        }
        return nil
    }

    /// A quota or entitlement `RTSError` that a sub-agent raised inside one of this agent's tool
    /// calls.
    ///
    /// The sub-agent's own session already mapped it, but the tool bridge rethrows it into Apple's
    /// tool loop, which wraps it in `LanguageModelSession.ToolCallError` — so without this the app
    /// would see the wrapper. Surfaced whatever this agent's provider is: an on-device orchestrator
    /// can call a Private Cloud Compute sub-agent. Other errors stay wrapped, as before.
    private static func errorFromToolCall(_ error: Error) -> RTSError? {
        guard #available(macOS 26, iOS 26, *) else {
            return nil
        }
        var current = error
        for _ in 0..<maximumUnderlyingDepth {
            guard let toolCallError = current as? LanguageModelSession.ToolCallError else {
                break
            }
            current = toolCallError.underlyingError
        }
        guard let rtsError = current as? RTSError else {
            return nil
        }
        switch rtsError {
        case .quotaLimitReached, .missingEntitlement:
            return rtsError
        default:
            return nil
        }
    }

    /// The PCC quota now: not reached, with no reset date, below OS 27.
    static func privateCloudComputeQuota() -> QuotaState {
        // XCODE26-SDK and OS26-FLOOR: as in `rtsError(for:provider:currentQuota:)`.
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            let quotaUsage = PrivateCloudComputeLanguageModel().quotaUsage
            return QuotaState(
                isLimitReached: quotaUsage.isLimitReached,
                resetDate: quotaUsage.resetDate
            )
        }
        #endif
        return QuotaState(isLimitReached: false, resetDate: nil)
    }

    /// Whether the missing-entitlement error is `error` or anywhere among its underlying errors.
    static func hasMissingEntitlementError(_ error: Error) -> Bool {
        hasMissingEntitlementError(error as NSError, depth: 0)
    }

    private static func hasMissingEntitlementError(_ error: NSError, depth: Int) -> Bool {
        if error.domain == missingEntitlementDomain, error.code == missingEntitlementCode {
            return true
        }
        guard depth < maximumUnderlyingDepth else {
            return false
        }
        var underlying: [NSError] = []
        if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            underlying.append(single)
        }
        if let multiple = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            underlying.append(contentsOf: multiple)
        }
        return underlying.contains { hasMissingEntitlementError($0, depth: depth + 1) }
    }
}
