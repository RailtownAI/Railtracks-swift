//
//  RTSRAGRateGovernorManagerTests.swift
//  RailtracksSwiftRAGTests
//
//  Created by Mark Su on 2026-09-22.
//

import Foundation
import Testing
@testable import RailtracksSwiftRAG

/// The registry that keeps one governor per metered budget.
///
/// Every case here asserts on **identity**, not equality: two embedders that merely hold
/// equivalent governors still climb and back off independently, which is the exact failure this
/// type exists to prevent.
@Suite("RailtracksSwiftRAG rate governor manager")
struct RTSRAGRateGovernorManagerTests {

    private static let endpoint = URL(string: "https://api.openai.com/v1")!

    @Test("the same budget returns the same instance")
    func sameBudgetIsShared() {
        let manager = RTSRAGRateGovernorManager()
        let budget = RTSRAGRateBudget(endpoint: Self.endpoint, model: "text-embedding-3-small", apiKey: "sk-a")

        let first = manager.governor(for: budget)
        let second = manager.governor(for: budget)

        #expect(first === second)
        #expect(manager.budgetCount == 1)
    }

    @Test("a different model, key or endpoint each gets its own")
    func distinctBudgetsAreSeparate() {
        let manager = RTSRAGRateGovernorManager()
        let base = manager.governor(
            for: RTSRAGRateBudget(endpoint: Self.endpoint, model: "text-embedding-3-small", apiKey: "sk-a")
        )
        let otherModel = manager.governor(
            for: RTSRAGRateBudget(endpoint: Self.endpoint, model: "text-embedding-3-large", apiKey: "sk-a")
        )
        let otherKey = manager.governor(
            for: RTSRAGRateBudget(endpoint: Self.endpoint, model: "text-embedding-3-small", apiKey: "sk-b")
        )
        let otherEndpoint = manager.governor(
            for: RTSRAGRateBudget(
                endpoint: URL(string: "https://gateway.example.com/v1")!,
                model: "text-embedding-3-small",
                apiKey: "sk-a"
            )
        )

        // All three axes meter separately. Sharing across a model would let one model's 429
        // throttle the other; sharing across a key or endpoint would merge two accounts.
        #expect(base !== otherModel)
        #expect(base !== otherKey)
        #expect(base !== otherEndpoint)
        #expect(manager.budgetCount == 4)
    }

    @Test("the API key is fingerprinted, not retained")
    func apiKeyIsNotStored() {
        let budget = RTSRAGRateBudget(endpoint: Self.endpoint, model: "text-embedding-3-small", apiKey: "sk-secret-value")

        // A registry holding live credentials would put them in every memory dump and log line
        // that touches it. Different keys still produce different budgets, which is all that is
        // needed — retaining the key is not.
        #expect(!budget.description.contains("sk-secret-value"))
        #expect("\(budget)".contains("text-embedding-3-small"))
    }

    // MARK: - Through the embedder, where the rule is actually applied

    @Test("embedders differing only in dimensions share one governor")
    func dimensionsDoNotSplitTheBudget() async {
        let manager = RTSRAGRateGovernorManager()
        let full = RTSRAGOpenAIEmbedding(apiKey: "sk-a", governors: manager)
        let narrow = RTSRAGOpenAIEmbedding(apiKey: "sk-a", dimensions: 256, governors: manager)

        // Different vector spaces — so different stores — but one quota. Keying a registry by
        // `modelIdentifier` would get this backwards, since that carries the dimension count.
        #expect(full.modelIdentifier != narrow.modelIdentifier)
        #expect(manager.budgetCount == 1)
    }

    @Test("embedders on different models do not share one governor")
    func modelsSplitTheBudget() async {
        let manager = RTSRAGRateGovernorManager()
        _ = RTSRAGOpenAIEmbedding(apiKey: "sk-a", model: "text-embedding-3-small", governors: manager)
        _ = RTSRAGOpenAIEmbedding(apiKey: "sk-a", model: "text-embedding-3-large", governors: manager)

        #expect(manager.budgetCount == 2)
    }

    @Test("a shared governor throttles the embedders together")
    func sharedGovernorIsOneBudget() async throws {
        let manager = RTSRAGRateGovernorManager()
        let budget = RTSRAGRateBudget(endpoint: Self.endpoint, model: "text-embedding-3-small", apiKey: "sk-a")
        _ = RTSRAGOpenAIEmbedding(apiKey: "sk-a", governors: manager)
        _ = RTSRAGOpenAIEmbedding(apiKey: "sk-a", dimensions: 256, governors: manager)
        let governor = manager.governor(for: budget)

        // The whole point, stated as behaviour rather than identity: a back-off recorded through
        // the budget is the *same* state both embedders will acquire permits from. With one
        // governor each, this halving would be invisible to the other.
        let before = await governor.currentLimit
        await governor.recordBackoff(retryAfter: 0)
        let after = await governor.currentLimit

        #expect(after < before)
        #expect(manager.budgetCount == 1)
    }

    @Test("a custom factory supplies the tuning for every new budget")
    func factoryTunesNewGovernors() async {
        let manager = RTSRAGRateGovernorManager {
            RTSRAGRateGovernor(initialLimit: 2, maximumLimit: 4)
        }
        let governor = manager.governor(
            for: RTSRAGRateBudget(endpoint: Self.endpoint, model: "voyage-3", apiKey: "sk-a")
        )

        // A provider metering per hour rather than per minute wants different limits, and gets
        // them without the registry knowing anything about providers.
        #expect(await governor.currentLimit == 2)
    }
}
