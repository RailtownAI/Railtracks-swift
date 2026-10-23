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

// MARK: - Foundation Models

#if canImport(FoundationModels)
// XCODE26-SDK: `ContextOptions` and `PrivateCloudComputeLanguageModel` need the OS 27 SDK
// (Xcode 27, Swift 6.4).
#if compiler(>=6.4)
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
#endif
#endif
