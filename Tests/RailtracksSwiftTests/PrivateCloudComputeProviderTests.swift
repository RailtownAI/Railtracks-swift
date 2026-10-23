//
//  PrivateCloudComputeProviderTests.swift
//  RailtracksSwiftTests
//
//  `.privateCloudCompute`: Apple's server model behind the Foundation Models API. Nothing here
//  needs the PCC entitlement or makes a network call — identity, pricing, events and concurrency
//  are pure, and building a session only constructs it. See docs/private-cloud-compute.md.
//

import Testing
import Foundation
@testable import RailtracksSwift
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite("Private Cloud Compute provider")
struct PrivateCloudComputeProviderTests {

    // MARK: - Identity

    @Test("It reports its own kind, name and model id")
    func reportsIdentity() {
        let provider = RTSLLMProvider.privateCloudCompute()

        #expect(provider.kind == .privateCloudCompute)
        #expect(provider.providerName == "AppleAIPrivateCloudCompute")
        #expect(provider.modelID == "private-cloud-compute")
        #expect(provider.description == "AppleAI-PrivateCloudCompute")
    }

    @Test("allCases holds one Private Cloud Compute entry")
    func appearsOnceInAllCases() {
        let entries = RTSLLMProvider.allCases.filter { $0.kind == .privateCloudCompute }

        #expect(entries.count == 1)
    }

    // MARK: - Local versus billed

    @Test("It is remote but not billed")
    func remoteButNotBilled() {
        let provider = RTSLLMProvider.privateCloudCompute()

        // The two questions `isLocal` used to answer together: PCC is a network call, yet costs
        // the developer nothing.
        #expect(provider.isLocal == false)
        #expect(provider.isBilled == false)
        #expect(RTSLLMProvider.isBilled(providerName: provider.providerName) == false)
    }

    @Test("Billing by provider name is unchanged for every other provider")
    func billingByNameIsUnchanged() {
        #expect(RTSLLMProvider.isBilled(providerName: "OpenAI"))
        #expect(RTSLLMProvider.isBilled(providerName: "Anthropic"))
        #expect(RTSLLMProvider.isBilled(providerName: "Gemini"))
        #expect(RTSLLMProvider.isBilled(providerName: "AppleAI") == false)
        // An unknown or missing name is still looked up in the pricing map, as before.
        #expect(RTSLLMProvider.isBilled(providerName: "something else"))
        #expect(RTSLLMProvider.isBilled(providerName: ""))
    }

    @Test("Its signpost cost is zero even with tokens")
    func signpostCostIsZero() async {
        let cost = await RTSFlowGraphCollector.computeCost(
            model: "gpt-4o",
            provider: "AppleAIPrivateCloudCompute",
            inputTokens: 1_000,
            outputTokens: 1_000
        )

        let billedCost = await RTSFlowGraphCollector.computeCost(
            model: "gpt-4o",
            provider: "OpenAI",
            inputTokens: 1_000,
            outputTokens: 1_000
        )

        // The same priced model and tokens cost something on a billed provider, so only the billed
        // check can make PCC's zero.
        #expect(billedCost > 0)
        #expect(cost == 0)
    }

    // MARK: - Events and concurrency

    @Test("Its event wire value is Apple's")
    func wireValueIsApple() {
        #expect(RTSEventModelProvider.wireValue(for: "AppleAIPrivateCloudCompute") == "apple")
    }

    @Test("Evaluations cap it at four concurrent calls")
    func defaultConcurrencyLimit() {
        #expect(RTSConcurrencyLimits.default.limit(for: .privateCloudCompute) == 4)
    }

    // MARK: - Options

    @Test("Options default to no reasoning level")
    func optionsDefaultToNoReasoningLevel() {
        guard case .privateCloudCompute(let options) = RTSLLMProvider.privateCloudCompute() else {
            Issue.record("expected .privateCloudCompute")
            return
        }

        #expect(options.reasoningLevel == nil)
    }
}

// MARK: - Errors

@Suite("Private Cloud Compute errors")
struct PrivateCloudComputeErrorTests {

    private static let resetDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let quotaNotReached = FoundationModelsErrorMapping.QuotaState(
        isLimitReached: false,
        resetDate: nil
    )

    /// The error a request failed with on an un-entitled macOS 27 Mac, rebuilt: three deep through
    /// `NSMultipleUnderlyingErrorsKey`, with the telling code only at the bottom.
    private static func entitlementFailure(innermostCode: Int = 1046) -> NSError {
        let innermost = NSError(
            domain: "ModelManagerServices.ModelManagerError",
            code: innermostCode
        )
        let middle = NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [innermost]]
        )
        return NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [middle]]
        )
    }

    @Test("A quota error's description carries its reset date")
    func quotaDescriptionCarriesDate() {
        let error = RTSError.quotaLimitReached(
            provider: "AppleAIPrivateCloudCompute",
            resetDate: Self.resetDate
        )

        #expect(error.description == """
            quotaLimitReached(provider: "AppleAIPrivateCloudCompute", \
            resetDate: "2027-01-15T08:00:00Z")
            """)
    }

    @Test("A quota error without a date says so")
    func quotaDescriptionWithoutDate() {
        let error = RTSError.quotaLimitReached(
            provider: "AppleAIPrivateCloudCompute",
            resetDate: nil
        )

        #expect(error.description
            == #"quotaLimitReached(provider: "AppleAIPrivateCloudCompute", resetDate: nil)"#)
    }

    @Test("The missing-entitlement error names the entitlement")
    func entitlementDescription() {
        let error = RTSError.missingEntitlement(name: "com.apple.developer.private-cloud-compute")

        #expect(error.description
            == #"missingEntitlement(name: "com.apple.developer.private-cloud-compute")"#)
    }

    @Test("The missing-entitlement failure maps to missingEntitlement")
    func entitlementFailureMaps() {
        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: Self.entitlementFailure(),
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaNotReached }
        )

        guard case .missingEntitlement(let name, _)? = rtsError else {
            Issue.record("expected missingEntitlement, got \(String(describing: rtsError))")
            return
        }
        #expect(name == "com.apple.developer.private-cloud-compute")
    }

    @Test("The same shape without code 1046 has no RTSError")
    func otherCodeHasNoRTSError() {
        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: Self.entitlementFailure(innermostCode: 1047),
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaNotReached }
        )

        #expect(rtsError == nil)
    }

    @Test("Code 1046 under another provider has no RTSError")
    func entitlementCodeElsewhereHasNoRTSError() {
        // Undocumented, so only trusted where it was measured: Private Cloud Compute.
        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: Self.entitlementFailure(),
            provider: .appleAI,
            currentQuota: { Self.quotaNotReached }
        )

        #expect(rtsError == nil)
    }

    @Test("An unrelated error has no RTSError, so it is rethrown as it is")
    func unrelatedErrorHasNoRTSError() {
        struct Unrelated: Error {}

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: Unrelated(),
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaNotReached }
        )

        #expect(rtsError == nil)
    }
}

// MARK: - Foundation Models

#if canImport(FoundationModels)
// XCODE26-SDK: `ContextOptions` and `PrivateCloudComputeLanguageModel` need the OS 27 SDK
// (Xcode 27, Swift 6.4).
#if compiler(>=6.4)
/// Stands in for the sub-agent tool a `ToolCallError` names; never called.
@available(macOS 26, iOS 26, *)
private struct SubAgentProbeTool: Tool {
    let name = "subAgentProbe"
    let description = "Stands in for a sub-agent tool."

    @Generable
    struct Arguments {
        var prompt: String
    }

    func call(arguments: Arguments) async throws -> String {
        ""
    }
}

@Suite("Private Cloud Compute session")
struct PrivateCloudComputeSessionTests {

    @Test("Each reasoning level becomes Apple's context option")
    func reasoningLevelsMap() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let cases: [(RTSPrivateCloudComputeReasoningLevel, ContextOptions.ReasoningLevel)] = [
            (.light, .light),
            (.moderate, .moderate),
            (.deep, .deep),
        ]
        for (level, expected) in cases {
            let options = AppleAISession.contextOptions(for: level, hasSchema: false)

            #expect(options == ContextOptions(reasoningLevel: expected))
        }
    }

    @Test("Structured output keeps the schema in the prompt")
    func schemaStaysInPrompt() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let options = AppleAISession.contextOptions(for: .light, hasSchema: true)

        // Apple's own default for `respond(to:schema:)`; passing any options replaces it, so it
        // must be carried over or the schema silently stops being sent.
        #expect(options == ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .light))
    }

    @Test("No reasoning level means no context options at all")
    func noLevelNoOptions() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }

        #expect(AppleAISession.contextOptions(for: nil, hasSchema: false) == nil)
        #expect(AppleAISession.contextOptions(for: nil, hasSchema: true) == nil)
    }

    @Test("The gateway builds a session without a network call")
    func gatewayBuildsSession() throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let agent = RTSAgent(
            llmProvider: .privateCloudCompute(
                options: RTSPrivateCloudComputeOptions(reasoningLevel: .light)
            ),
            name: "PCC Session Probe"
        )
        let gateway = RTSLLMGateway(apiKeys: [:])
        let invoker = RTSNodeInvoker(stampFactory: RTSStampFactory(), sessionID: UUID())

        // Construction only: no request is sent, so this needs neither the entitlement nor a
        // network, and must not throw `providerUnavailable` on macOS 27.
        _ = try gateway.session(invoker: invoker, agentNode: agent, onNewSession: { _ in })
    }
}

@Suite("Private Cloud Compute quota and entitlement mapping")
struct PrivateCloudComputeQuotaMappingTests {

    private static let thrownResetDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let currentResetDate = Date(timeIntervalSince1970: 1_800_086_400)
    private static let quotaNotReached = FoundationModelsErrorMapping.QuotaState(
        isLimitReached: false,
        resetDate: nil
    )
    private static let quotaReached = FoundationModelsErrorMapping.QuotaState(
        isLimitReached: true,
        resetDate: currentResetDate
    )

    /// The quota error's provider and reset date, or `nil` when `rtsError` is not one.
    private static func quota(_ rtsError: RTSError?) -> (provider: String, resetDate: Date?)? {
        guard case .quotaLimitReached(let provider, let resetDate, _)? = rtsError else {
            return nil
        }
        return (provider, resetDate)
    }

    @Test("PCC's quota error maps with its own reset date")
    func quotaErrorKeepsItsDate() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let thrown = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
            .init(resetDate: Self.thrownResetDate, debugDescription: "daily limit")
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: thrown,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaReached }
        )

        let quota = Self.quota(rtsError)
        #expect(quota?.provider == "AppleAIPrivateCloudCompute")
        #expect(quota?.resetDate == Self.thrownResetDate)
    }

    @Test("Without a date on the error, the quota's current reset date is used")
    func quotaErrorFallsBackToCurrentDate() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let thrown = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
            .init(resetDate: nil, debugDescription: "daily limit")
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: thrown,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaReached }
        )

        #expect(Self.quota(rtsError)?.resetDate == Self.currentResetDate)
    }

    @Test("With no date anywhere, the quota error still maps, dateless")
    func quotaErrorWithNoDateAnywhere() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let thrown = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
            .init(resetDate: nil, debugDescription: "daily limit")
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: thrown,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaNotReached }
        )

        let quota = Self.quota(rtsError)
        #expect(quota != nil)
        #expect(quota?.resetDate == nil)
    }

    @Test("A rate limit on PCC maps to the quota error, with its date")
    func rateLimitOnPrivateCloudComputeMaps() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let thrown = LanguageModelError.rateLimited(
            .init(resetDate: Self.thrownResetDate, debugDescription: "rate limited")
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: thrown,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaReached }
        )

        #expect(Self.quota(rtsError)?.resetDate == Self.thrownResetDate)
    }

    @Test("A rate limit on PCC is not the daily limit while the quota is not reached")
    func rateLimitBelowQuotaHasNoRTSError() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let thrown = LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "rate limited")
        )

        // A short rate limit: reporting it as the daily limit, with tomorrow's reset date, would
        // have an app disable the feature for hours over something that clears in seconds.
        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: thrown,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaNotReached }
        )

        #expect(rtsError == nil)
    }

    @Test("A dateless rate limit at the daily limit takes the quota's reset date")
    func rateLimitAtQuotaTakesQuotaDate() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let thrown = LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "rate limited")
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: thrown,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaReached }
        )

        #expect(Self.quota(rtsError)?.resetDate == Self.currentResetDate)
    }

    @Test("A rate limit on another model has no RTSError")
    func rateLimitElsewhereHasNoRTSError() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let claude = RTSFoundationLanguageModel(
            SystemLanguageModel.default,
            kind: .anthropic,
            modelID: "claude-sonnet-4-6"
        )
        let thrown = LanguageModelError.rateLimited(
            .init(resetDate: Self.thrownResetDate, debugDescription: "rate limited")
        )

        // From Claude, a rate limit is the provider's, not a daily quota.
        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: thrown,
            provider: .foundationModel(claude),
            currentQuota: { Self.quotaNotReached }
        )

        #expect(rtsError == nil)
    }

    @Test("A sub-agent's quota error surfaces through the tool call that wrapped it")
    func subAgentQuotaErrorSurfaces() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let subAgentError = RTSError.quotaLimitReached(
            provider: "AppleAIPrivateCloudCompute",
            resetDate: Self.thrownResetDate
        )
        // How Apple's tool loop hands back a sub-agent failure: wrapped, here twice over, as an
        // orchestrator calling an orchestrator would.
        let inner = LanguageModelSession.ToolCallError(
            tool: SubAgentProbeTool(),
            underlyingError: subAgentError
        )
        let outer = LanguageModelSession.ToolCallError(
            tool: SubAgentProbeTool(),
            underlyingError: inner
        )

        // An on-device parent: surfaced whatever the parent's provider is.
        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: outer,
            provider: .appleAI,
            currentQuota: { Self.quotaNotReached }
        )

        #expect(Self.quota(rtsError)?.resetDate == Self.thrownResetDate)
    }

    @Test("A sub-agent's missing entitlement surfaces through the tool call that wrapped it")
    func subAgentEntitlementErrorSurfaces() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let wrapped = LanguageModelSession.ToolCallError(
            tool: SubAgentProbeTool(),
            underlyingError: RTSError.missingEntitlement(
                name: "com.apple.developer.private-cloud-compute"
            )
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: wrapped,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaNotReached }
        )

        guard case .missingEntitlement? = rtsError else {
            Issue.record("expected missingEntitlement, got \(String(describing: rtsError))")
            return
        }
    }

    @Test("Other sub-agent errors stay wrapped")
    func otherSubAgentErrorsStayWrapped() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let wrapped = LanguageModelSession.ToolCallError(
            tool: SubAgentProbeTool(),
            underlyingError: RTSError.missingInput("prompt")
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: wrapped,
            provider: .privateCloudCompute(),
            currentQuota: { Self.quotaNotReached }
        )

        #expect(rtsError == nil)
    }

    @Test("A PCC model wrapped in .foundationModel gets the entitlement error too")
    func wrappedPrivateCloudComputeMapsEntitlement() {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        let wrapped = RTSFoundationLanguageModel(
            PrivateCloudComputeLanguageModel(),
            kind: .privateCloudCompute,
            modelID: "private-cloud-compute"
        )
        let innermost = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1046)
        let failure = NSError(
            domain: "FoundationModels.LanguageModelError",
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [innermost]]
        )

        let rtsError = FoundationModelsErrorMapping.rtsError(
            for: failure,
            provider: .foundationModel(wrapped),
            currentQuota: { Self.quotaNotReached }
        )

        guard case .missingEntitlement? = rtsError else {
            Issue.record("expected missingEntitlement, got \(String(describing: rtsError))")
            return
        }
    }

    /// Live, and only meaningful *without* the entitlement — which a test binary never has. Sends
    /// one real request through the gateway; skips where PCC reports itself unavailable.
    @Test("A run on this un-entitled machine throws missingEntitlement")
    func liveRunWithoutEntitlement() async throws {
        guard #available(macOS 27, iOS 27, *) else {
            return
        }
        guard PrivateCloudComputeLanguageModel().isAvailable else {
            print("⏭️ Private Cloud Compute unavailable; skipping live entitlement check")
            return
        }
        let agent = RTSAgent(llmProvider: .privateCloudCompute(), name: "PCC Entitlement Probe")
        let gateway = RTSLLMGateway(apiKeys: [:])
        let invoker = RTSNodeInvoker(stampFactory: RTSStampFactory(), sessionID: UUID())
        let session = try gateway.session(
            invoker: invoker,
            agentNode: agent,
            onNewSession: { _ in }
        )

        do {
            _ = try await session.run("Reply with the single word: hello", runID: UUID())
            Issue.record("expected the request to fail without the entitlement")
        } catch {
            guard case .missingEntitlement(let name, _) = error as? RTSError else {
                Issue.record("expected missingEntitlement, got \(error)")
                return
            }
            #expect(name == "com.apple.developer.private-cloud-compute")
        }
    }
}
#endif
#endif
