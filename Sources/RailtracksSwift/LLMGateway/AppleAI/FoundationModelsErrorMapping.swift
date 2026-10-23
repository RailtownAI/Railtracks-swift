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

    /// The error a request fails with when the app lacks the PCC entitlement, measured on macOS 27:
    /// a plain `NSError` nesting this one beneath two `FoundationModels.LanguageModelError` code -1
    /// wrappers. Undocumented, so only trusted when the provider is Private Cloud Compute.
    static let missingEntitlementDomain = "ModelManagerServices.ModelManagerError"
    static let missingEntitlementCode = 1046

    /// How deep to search an error's underlying errors. The measured nesting is three; the limit
    /// only guards against a cycle.
    private static let maximumUnderlyingDepth = 8

    /// The `RTSError` an app should see instead of `error`, or `nil` when there is none and
    /// `error` should be rethrown as it is.
    ///
    /// - Parameters:
    ///   - error: What `respond` threw.
    ///   - provider: The agent's provider. Only Private Cloud Compute's kind enables the
    ///     entitlement and rate-limit mappings, whether chosen as `.privateCloudCompute` or wrapped
    ///     in `.foundationModel`.
    ///   - currentQuotaResetDate: The quota's reset date right now, used when the thrown error
    ///     carries none. Injected so tests can control it.
    static func rtsError(
        for error: Error,
        provider: RTSLLMProvider,
        currentQuotaResetDate: () -> Date? = Self.privateCloudComputeQuotaResetDate
    ) -> RTSError? {
        let isPrivateCloudCompute = provider.kind == .privateCloudCompute
        // XCODE26-SDK: both error types exist only in the OS 27 SDK (Xcode 27, Swift 6.4).
        #if compiler(>=6.4)
        // OS26-FLOOR: both are OS 27 API, and nothing below OS 27 can throw them.
        if #available(macOS 27, iOS 27, *),
           let thrownResetDate = quotaResetDate(
               of: error,
               includingRateLimit: isPrivateCloudCompute
           ) {
            return RTSError.quotaLimitReached(
                provider: provider.providerName,
                resetDate: thrownResetDate ?? currentQuotaResetDate()
            )
        }
        #endif
        if isPrivateCloudCompute, hasMissingEntitlementError(error) {
            return RTSError.missingEntitlement(name: privateCloudComputeEntitlement)
        }
        return nil
    }

    // XCODE26-SDK: as above.
    #if compiler(>=6.4)
    /// For a quota error, the reset date it carries (which may itself be `nil`); `nil` when the
    /// error is not a quota error at all.
    ///
    /// `LanguageModelError.rateLimited` counts only for Private Cloud Compute, in case Apple
    /// reports the daily limit through it. From another model, Claude say, it means a provider rate
    /// limit, not a quota, and is left as it is.
    @available(macOS 27, iOS 27, *)
    private static func quotaResetDate(of error: Error, includingRateLimit: Bool) -> Date?? {
        if let quotaError = error as? PrivateCloudComputeLanguageModel.Error,
           case .quotaLimitReached(let info) = quotaError {
            return .some(info.resetDate)
        }
        if includingRateLimit,
           let modelError = error as? LanguageModelError,
           case .rateLimited(let info) = modelError {
            return .some(info.resetDate)
        }
        return nil
    }
    #endif

    /// The PCC quota's reset date now, or `nil` below OS 27 or when Apple gives none.
    static func privateCloudComputeQuotaResetDate() -> Date? {
        // XCODE26-SDK and OS26-FLOOR: as in `map`.
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            return PrivateCloudComputeLanguageModel().quotaUsage.resetDate
        }
        #endif
        return nil
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
