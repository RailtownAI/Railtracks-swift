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
        self.endpoint = RTSRAGRateBudget.canonical(endpoint)
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

extension RTSRAGRateBudget {

    /// Canonical spelling of an endpoint, so two ways of writing one URL are one budget.
    ///
    /// Raw `absoluteString` made `…/v1` and `…/v1/` distinct budgets, and lower-cased a host into a
    /// third — silently splitting one quota in exactly the way this type exists to prevent. Scheme
    /// and host are case-insensitive per RFC 3986, and a trailing slash on a base URL carries no
    /// meaning here.
    ///
    /// The query is **kept**: Azure OpenAI's mandatory `?api-version=` is part of which endpoint
    /// this is, not decoration.
    private static func canonical(_ endpoint: URL) -> String {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path
        return components.string ?? endpoint.absoluteString
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
/// Entries are never evicted, which suits the shape this is built for: an app with a handful of
/// (endpoint, model, key) triples fixed at startup, each governor a few integers and a waiter
/// queue. **A process minting budgets at runtime is the case it does not suit** — a multi-tenant
/// service holding one key per customer, or a long-lived process rotating keys, would grow this
/// map without bound. Hold a manager per tenant there, or evict around it; this type deliberately
/// has no opinion, because a lifetime policy guessed in advance is worse than none.
public final class RTSRAGRateGovernorManager: Sendable {

    private let governors = Mutex<[RTSRAGRateBudget: RTSRAGRateGovernor]>([:])
    private let makeGovernor: @Sendable () -> RTSRAGRateGovernor

    /// - Parameter makeGovernor: Builds a governor for a budget seen for the first time. Supply one
    ///   to tune limits for a provider whose windows differ from OpenAI's per-minute ones.
    public init(makeGovernor: @escaping @Sendable () -> RTSRAGRateGovernor = { RTSRAGRateGovernor() }) {
        self.makeGovernor = makeGovernor
    }

    /// The governor for `budget`, created on first ask and returned unchanged after that.
    ///
    /// Synchronous, so it can be called from an embedder's `init`, which cannot `await`.
    public func governor(for budget: RTSRAGRateBudget) -> RTSRAGRateGovernor {
        if let existing = governors.withLock({ $0[budget] }) {
            return existing
        }
        // Built **outside** the lock. `makeGovernor` is the caller's closure, and holding a lock
        // across someone else's code is the habit that eventually deadlocks — a factory that
        // reached back into this manager would hang on a non-reentrant `Mutex`. The same rule
        // ``RTSRAGRateGovernor`` follows when it resumes a continuation.
        let created = makeGovernor()
        return governors.withLock { governors in
            // Another caller may have won while this one was building. Theirs is already visible,
            // so it wins and ours is dropped — one instance per budget is the invariant, and a
            // governor nobody acquires from is inert.
            if let raced = governors[budget] {
                return raced
            }
            governors[budget] = created
            return created
        }
    }

    /// How many distinct budgets this manager holds, for an app that wants to log or assert on it.
    public var budgetCount: Int {
        governors.withLock { $0.count }
    }
}
