//
//  RTSRAGRateGovernorManager.swift
//  RailtracksSwiftRAG
//
//  Created by Mark Su on 2026-09-22.
//

import Crypto
import Foundation
import Synchronization

// MARK: - RTSRAGRateBudget

/// One metered budget: the unit a provider counts requests and tokens against.
///
/// Exactly the scope a ``RTSRAGRateGovernor`` may cover — OpenAI meters per API key *per model*,
/// and a different endpoint is a different account entirely. Making it a value means the rule is
/// expressed once, in a type, rather than restated in every doc comment that touches sharing.
///
/// **The API key is fingerprinted, never stored.** Two keys must produce different budgets, which
/// needs only that they differ — not that the key be retained. A registry holding live credentials
/// as dictionary keys would put them in every memory dump and `description` that touches it, for no
/// gain.
public struct RTSRAGRateBudget: Hashable, Sendable {

    private let endpoint: String
    private let model: String
    private let keyFingerprint: String

    /// - Parameters:
    ///   - endpoint: The provider's base URL. Distinguishes OpenAI from a gateway or a self-hosted
    ///     endpoint, which meter separately even when the model name matches.
    ///   - model: The model name. Not ``RTSRAGEmbedding/modelIdentifier`` — that carries the
    ///     requested `dimensions`, and truncating a vector does not give it its own quota, so two
    ///     embedders differing only in width share one budget and must share one governor.
    ///   - apiKey: Fingerprinted on the way in.
    public init(
        endpoint: URL,
        model: String,
        apiKey: String
    ) {
        self.endpoint = endpoint.absoluteString
        self.model = model
        // Truncated because this only has to separate keys within one process, and a shorter value
        // keeps the type cheap to hash and log.
        self.keyFingerprint = String(
            SHA256.hash(data: Data(apiKey.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(16)
        )
    }
}

extension RTSRAGRateBudget: CustomStringConvertible {
    public var description: String {
        "\(model) at \(endpoint) (key \(keyFingerprint))"
    }
}

// MARK: - RTSRAGRateGovernorManager

/// Hands out one ``RTSRAGRateGovernor`` per ``RTSRAGRateBudget``, creating it on first ask.
///
/// The rule this exists to enforce is easy to state and easy to get wrong by accident: everything
/// drawing on one provider budget must share one governor, or each copy climbs on its own successes
/// and backs off only on its own refusals, and together they exceed a budget neither can observe.
/// The failure is silent — every embedder behaves correctly on its own.
///
/// ```swift
/// let governors = RTSRAGRateGovernorManager()
/// let small = RTSRAGOpenAIEmbedding(apiKey: key, model: "text-embedding-3-small", governors: governors)
/// let large = RTSRAGOpenAIEmbedding(apiKey: key, model: "text-embedding-3-large", governors: governors)
/// let narrow = RTSRAGOpenAIEmbedding(apiKey: key, dimensions: 256, governors: governors)
/// ```
///
/// `small` and `narrow` share a governor — same key, same model, and `dimensions` does not earn its
/// own quota. `large` gets its own, because a different model is metered separately and sharing
/// would let one model's 429 throttle the other.
///
/// ## Not a singleton, deliberately
///
/// There is no `shared`. A process-wide registry would make every test share governor state, and
/// this suite runs in parallel — one test's back-off would shrink another's limit and the failure
/// would look like flakiness. An app holds one instance for as long as it wants the budgets shared,
/// which is the same lifetime it already gives its embedders.
///
/// ## Growth
///
/// Entries are never evicted. A governor is a few integers and a waiter queue, and the number of
/// distinct (endpoint, model, key) triples an app uses is small and fixed at startup, so eviction
/// would add a lifetime question to solve a problem that does not arise.
public final class RTSRAGRateGovernorManager: @unchecked Sendable {

    private let governors = Mutex<[RTSRAGRateBudget: RTSRAGRateGovernor]>([:])
    private let makeGovernor: @Sendable () -> RTSRAGRateGovernor

    /// - Parameter makeGovernor: Builds a governor for a budget seen for the first time. Supply one
    ///   to tune limits for a provider whose windows differ from OpenAI's per-minute ones.
    public init(makeGovernor: @escaping @Sendable () -> RTSRAGRateGovernor = { RTSRAGRateGovernor() }) {
        self.makeGovernor = makeGovernor
    }

    /// The governor for `budget`, created on first ask and returned unchanged after that.
    ///
    /// Synchronous, so it can be called from an embedder's `init`, which cannot `await`. The lookup
    /// and the insert happen under one lock acquisition, so two threads racing on a new budget
    /// cannot each build a governor and leave one of them orphaned — which would be precisely the
    /// duplicate this type exists to prevent.
    public func governor(for budget: RTSRAGRateBudget) -> RTSRAGRateGovernor {
        governors.withLock { governors in
            if let existing = governors[budget] {
                return existing
            }
            let created = makeGovernor()
            governors[budget] = created
            return created
        }
    }

    /// How many distinct budgets have been asked for. Diagnostics, and what a test asserts on to
    /// prove two embedders shared rather than duplicated.
    public var budgetCount: Int {
        governors.withLock { $0.count }
    }
}
