//
//  RTSError.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation

/// Where an `RTSError` was constructed.
///
/// Captured automatically by the static factories on `RTSError`, which take
/// `#fileID` / `#line` / `#function` as default arguments. Default arguments are
/// evaluated at the *call site*, so these describe the code that raised the error
/// rather than the factory itself.
///
/// A factory that wraps another factory would record its own location, so any such
/// helper must thread `file` / `line` / `function` through explicitly.
public struct RTSErrorContext: Sendable, Equatable {
    /// `#fileID` form — `"RailtracksSwift/RTSAgent.swift"`. Deliberately not `#file`,
    /// which would embed the absolute build path in the binary.
    public let file: String
    public let line: UInt
    public let function: String

    public init(
        file: String,
        line: UInt,
        function: String
    ) {
        self.file = file
        self.line = line
        self.function = function
    }
}

public enum RTSError: Error {
    case missingInput(String, context: RTSErrorContext)
    case missingOutput(String, context: RTSErrorContext)
    case encodingFailed(String? = nil, context: RTSErrorContext)
    case decodingFailed(String? = nil, context: RTSErrorContext)
    /// File write or encoding failed. The associated value is the attempted file path, if known.
    case writeFileFailed(String? = nil, context: RTSErrorContext)
    case invalidInvocation(String, context: RTSErrorContext)
    case invalidSchema(String, context: RTSErrorContext)
    case missingAPIKey(String, context: RTSErrorContext)
    /// Selected provider is not available on the current OS version (e.g. AppleAI below macOS/iOS 26).
    case providerUnavailable(String, context: RTSErrorContext)
    /// A guardrail blocked the run. Carries the guardrail's name, the stage it ran
    /// at (`.input` / `.output`), and the block reason.
    case guardrailBlocked(
        guardrailName: String,
        stage: RTSGuardrailStage,
        reason: String,
        context: RTSErrorContext
    )
    /// The provider's usage limit was reached — for Private Cloud Compute, the user's daily
    /// limit, counted against their iCloud account and raised by iCloud+.
    ///
    /// `resetDate` is when requests work again, when the provider says; an app can show it, or
    /// disable the action until then rather than retrying.
    case quotaLimitReached(provider: String, resetDate: Date?, context: RTSErrorContext)
    /// The app lacks an entitlement the provider requires — for Private Cloud Compute,
    /// `com.apple.developer.private-cloud-compute`.
    ///
    /// Raised only when a request fails: Private Cloud Compute reports itself available without
    /// the entitlement, so no availability check can catch this first.
    ///
    /// **A signed app never gets this error.** There, Apple's framework stops the app with a fatal
    /// error ("Missing entitlement: …") before the library can map anything; the thrown form is
    /// what unsigned processes, such as `swift test`, see. Treat the entitlement as a setup
    /// requirement: granted to the team, enabled on the App ID, and present in the app's
    /// entitlements file before any agent uses ``RTSLLMProvider/privateCloudCompute(options:)``.
    case missingEntitlement(name: String, context: RTSErrorContext)
}

// MARK: - Call-site capturing factories

/// Each case has a same-named static factory that fills in the call site.
///
/// The `context:` label on every case is what makes this unambiguous: the labelled
/// parameter means a call such as `RTSError.missingInput("prompt")` cannot match the
/// case constructor, so it resolves to the factory below. Existing **construction**
/// sites therefore compile unchanged and gain the context for free.
///
/// **Pattern matches are not covered by that.** The `context:` payload has no default, so every
/// `catch`/`case` that binds a payload gained an element — `case .missingInput(let detail)` must
/// become `case .missingInput(let detail, _)`. Adopting this required fixing three such matches
/// (two in `GuardrailTests`, one in the demo's `GuardrailsViewModel`). A match that omits the
/// payload pattern entirely (`case .missingAPIKey:`) still compiles untouched.
///
/// Adding a case, or another payload, carries the same cost — worth knowing before the library
/// is published and the enum's shape becomes an external commitment.
///
/// One further caveat: an *unapplied* reference (`let make = RTSError.missingInput`) binds
/// to the case, not the factory, and will fail to typecheck. Always call these directly.
extension RTSError {
    public static func missingInput(
        _ detail: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .missingInput(detail, context: context)
    }

    public static func missingOutput(
        _ detail: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .missingOutput(detail, context: context)
    }

    public static func encodingFailed(
        _ detail: String? = nil,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .encodingFailed(detail, context: context)
    }

    public static func decodingFailed(
        _ detail: String? = nil,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .decodingFailed(detail, context: context)
    }

    public static func writeFileFailed(
        _ detail: String? = nil,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .writeFileFailed(detail, context: context)
    }

    public static func invalidInvocation(
        _ detail: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .invalidInvocation(detail, context: context)
    }

    public static func invalidSchema(
        _ detail: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .invalidSchema(detail, context: context)
    }

    public static func missingAPIKey(
        _ detail: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .missingAPIKey(detail, context: context)
    }

    public static func providerUnavailable(
        _ detail: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .providerUnavailable(detail, context: context)
    }

    public static func guardrailBlocked(
        guardrailName: String,
        stage: RTSGuardrailStage,
        reason: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .guardrailBlocked(
            guardrailName: guardrailName,
            stage: stage,
            reason: reason,
            context: context
        )
    }

    public static func quotaLimitReached(
        provider: String,
        resetDate: Date?,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .quotaLimitReached(provider: provider, resetDate: resetDate, context: context)
    }

    public static func missingEntitlement(
        name: String,
        file: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) -> RTSError {
        let context = RTSErrorContext(file: file, line: line, function: function)
        return .missingEntitlement(name: name, context: context)
    }
}

// MARK: - Context access

extension RTSError {
    /// The call site that raised this error.
    public var context: RTSErrorContext {
        switch self {
        case .missingInput(_, let context),
             .missingOutput(_, let context),
             .encodingFailed(_, let context),
             .decodingFailed(_, let context),
             .writeFileFailed(_, let context),
             .invalidInvocation(_, let context),
             .invalidSchema(_, let context),
             .missingAPIKey(_, let context),
             .providerUnavailable(_, let context),
             .guardrailBlocked(_, _, _, let context),
             .quotaLimitReached(_, _, let context),
             .missingEntitlement(_, let context):
            return context
        }
    }
}

// MARK: - Description

/// Reproduces the reflected form the enum had *before* `context` was added, so the
/// exported JSON trace's `error` / `exception_message` strings are unchanged — that
/// format is a contract with other verticals.
///
/// The context is intentionally omitted here. Read it from `error.context` instead.
/// Removing this conformance would leak the context into every trace string.
extension RTSError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingInput(let detail, _):
            return "missingInput(\(String(reflecting: detail)))"
        case .missingOutput(let detail, _):
            return "missingOutput(\(String(reflecting: detail)))"
        case .encodingFailed(let detail, _):
            return "encodingFailed(\(String(reflecting: detail)))"
        case .decodingFailed(let detail, _):
            return "decodingFailed(\(String(reflecting: detail)))"
        case .writeFileFailed(let detail, _):
            return "writeFileFailed(\(String(reflecting: detail)))"
        case .invalidInvocation(let detail, _):
            return "invalidInvocation(\(String(reflecting: detail)))"
        case .invalidSchema(let detail, _):
            return "invalidSchema(\(String(reflecting: detail)))"
        case .missingAPIKey(let detail, _):
            return "missingAPIKey(\(String(reflecting: detail)))"
        case .providerUnavailable(let detail, _):
            return "providerUnavailable(\(String(reflecting: detail)))"
        case .guardrailBlocked(let guardrailName, let stage, let reason, _):
            let name = String(reflecting: guardrailName)
            let stageText = String(reflecting: stage)
            return "guardrailBlocked(guardrailName: \(name), "
                + "stage: \(stageText), reason: \(String(reflecting: reason)))"
        case .quotaLimitReached(let provider, let resetDate, _):
            // ISO 8601 in UTC, so the trace carries an unambiguous time rather than `Date`'s
            // reflected form.
            let resetText = resetDate.map { String(reflecting: $0.ISO8601Format()) } ?? "nil"
            return "quotaLimitReached(provider: \(String(reflecting: provider)), "
                + "resetDate: \(resetText))"
        case .missingEntitlement(let name, _):
            return "missingEntitlement(name: \(String(reflecting: name)))"
        }
    }
}
