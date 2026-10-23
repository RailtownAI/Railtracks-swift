//
//  RTSLLMRoundTrip.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-08.
//

import Foundation

// MARK: - RTSLLMRoundTrip

/// One provider round trip, reconstructed from a session's message log.
///
/// Conduit runs an agent's whole tool-calling loop inside a single `ChatSession.send`, so
/// Swift never observes the individual round trips and has to derive them afterwards. The
/// derivation is simple: **one round trip per assistant message**, whose input is every
/// message before it.
///
/// Shared by the two consumers so they cannot drift apart — the flow-graph parser
/// (`RTSFlowGraph+Parser.makeLLMDetails`) and the `llm.*` observability events.
///
/// Every provider-reported field is **optional here on purpose**. The flow graph substitutes
/// its own defaults (`0`, `"unknown"`) on the way out, and the event stream writes `null`;
/// baking either default in would change the other's output.
struct RTSLLMRoundTrip {
    /// Every message preceding `output` — what was sent to the provider for this trip.
    let messageInput: [RTSMessage]
    /// The assistant message this round trip produced.
    let output: RTSMessage
    let modelName: String?
    let modelProvider: String?
    let inputTokens: Int?
    let outputTokens: Int?
    /// `nil` for local providers, which are not priced, and when the model is unknown to the
    /// pricing map.
    let totalCost: Double?
    let systemFingerprint: String?
    let latency: TimeInterval?

    /// When the round trip's request went out, derived by winding back from the response by
    /// its reported latency. Falls back to the response's own timestamp when the provider
    /// reported none.
    ///
    /// Derived rather than observed: nothing records the request moment, because the request
    /// happens inside Conduit.
    var requestedAt: Date {
        output.timestamp.addingTimeInterval(-(latency ?? 0))
    }

    /// When the response arrived. A real timestamp, carried through from Conduit's `Message`.
    var respondedAt: Date {
        output.timestamp
    }
}

// MARK: - Reconstruction

extension RTSLLMRoundTrip {

    /// Walks a message log and returns one round trip per assistant message, in order.
    ///
    /// Awaits `RTSCostCalculator` per trip. That is a bare actor hop in the warm case —
    /// `preloadPricing()` runs at flow start and the map is cached with a 24-hour TTL — but a
    /// genuine cold start can reach the network here.
    static func reconstruct(from messages: [RTSMessage]) async -> [RTSLLMRoundTrip] {
        var roundTrips: [RTSLLMRoundTrip] = []
        for (index, message) in messages.enumerated() {
            guard message.role == .assistant else {
                continue
            }
            roundTrips.append(
                RTSLLMRoundTrip(
                    messageInput: Array(messages[0..<index]),
                    output: message,
                    modelName: message.metadata?.model,
                    modelProvider: message.metadata?.providerName,
                    inputTokens: message.metadata?.inputTokenCount,
                    outputTokens: message.metadata?.tokenCount,
                    totalCost: await cost(for: message)?.totalCost,
                    systemFingerprint: message.metadata?.providerExtra?["system_fingerprint"],
                    latency: message.metadata?.generationTime
                )
            )
        }
        return roundTrips
    }

    /// The priced cost of one assistant message, or `nil` when it cannot be priced.
    ///
    /// The defaults here are load-bearing and match what the flow-graph parser used before
    /// this was factored out: an absent provider reads as `""` for the billed check, while an
    /// absent model is looked up as `"unknown"` — which simply misses the pricing map.
    private static func cost(for message: RTSMessage) async -> RTSTokenCost? {
        let providerName = message.metadata?.providerName ?? ""
        guard RTSLLMProvider.isBilled(providerName: providerName) else {
            return nil
        }
        let usage = RTSTokenUsage(
            promptTokens: message.metadata?.inputTokenCount ?? 0,
            completionTokens: message.metadata?.tokenCount ?? 0
        )
        return try? await RTSCostCalculator.shared.calculateCost(
            model: message.metadata?.model ?? "unknown",
            usage: usage
        )
    }
}
