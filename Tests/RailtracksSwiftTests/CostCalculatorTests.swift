//
//  CostCalculatorTests.swift
//  RailtracksSwift
//
//  `RTSCostCalculator.cost(model:providerName:inputTokens:outputTokens:)`: the one place that
//  decides whether a call is billed and prices its tokens, shared by the `llm.*` events and the
//  signposts.
//

import Foundation
import Testing
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {

    @Suite("Cost calculator")
    struct CostCalculatorTests {

        @Test("An unbilled provider has no cost, even for a priced model and tokens")
        func unbilledProviderHasNoCost() async {
            let cost = await RTSCostCalculator.shared.cost(
                model: "gpt-4o",
                providerName: "AppleAI",
                inputTokens: 1_000,
                outputTokens: 1_000
            )
            #expect(cost == nil)
        }

        @Test("A billed provider is priced as calculateCost prices the same tokens")
        func billedProviderMatchesCalculateCost() async throws {
            let usage = RTSTokenUsage(promptTokens: 1_000, completionTokens: 500)
            let direct = try await RTSCostCalculator.shared.calculateCost(
                model: "gpt-4o",
                usage: usage
            )
            let cost = await RTSCostCalculator.shared.cost(
                model: "gpt-4o",
                providerName: "OpenAI",
                inputTokens: 1_000,
                outputTokens: 500
            )
            let expected = try #require(direct)
            #expect(cost?.totalCost == expected.totalCost)
            #expect((cost?.totalCost ?? 0) > 0)
        }

        @Test("A model missing from the pricing map has no cost")
        func unknownModelHasNoCost() async {
            let cost = await RTSCostCalculator.shared.cost(
                model: "no-such-model-for-pricing",
                providerName: "OpenAI",
                inputTokens: 1_000,
                outputTokens: 1_000
            )
            #expect(cost == nil)
        }
    }
}
