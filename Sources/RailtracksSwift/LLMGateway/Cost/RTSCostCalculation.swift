//
//  RTSCostCalculation.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-15
//  Last edited: 2026-05-15 10:54:12 PDT
//

import Foundation

/**
 ## Port details:
 Pricing fetch & fallback — mirrors get_model_cost_map.py:
 - Fetches from the same GitHub URL with a 5s timeout
 - On success, saves raw JSON to disk
 - On failure, falls back to the disk cache (analogous to LiteLLM's bundled model_prices_and_context_window_backup.json)
 - While the app is running the system will use the price map in memory, and every cacheTTL duration, it will release the map in memory and perform a refetch.
 - While the price map cache in disk is persisted across app launch, the system will try to refetch the json at every launch.
 - Original LITELLM_LOCAL_MODEL_COST_MAP=true env var check is removed

 Model resolution — mirrors cost_calculator.py's 3-step lookup:
 1. Exact key (e.g. "anthropic/claude-3-5-sonnet-20241022")
 2. Key without provider prefix (e.g. "claude-3-5-sonnet-20241022")
 3. Tries prepending common provider prefixes (e.g. "openai/gpt-4o" when caller passes "gpt-4o")

 Cost calculation — mirrors generic_cost_per_token in llm_cost_calc/utils.py:
 - Tiered input/output rates (128k / 200k / 272k token thresholds)
 - Cache read tokens at cache_read_input_token_cost
 - Cache creation tokens at cache_creation_input_token_cost
 - Reasoning tokens at output_cost_per_reasoning_token (fallback to output rate)
 - Audio tokens at input/output_cost_per_audio_token (fallback to base rate)
 - Text tokens computed as remainder to avoid double-counting

 One deliberate simplification: the disk cache TTL is 24 hours (LiteLLM fetches on every import with no TTL). The cache is at
 $TMPDIR/litellm_model_prices_cache.json.
 
 
 ```
 ┌─────────────────────┬───────────────────────────────────────────────┬───────────────────────────────────────────────────┐
 │        Swift        │                Python function                │                    Python file                    │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ RTSTokenUsage       │ Usage type                                    │ litellm/types/utils.py                            │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ RTSTokenCost        │ cost_per_token() return tuple                 │ litellm/cost_calculator.py                        │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ RTSCostCalculator   │ GetModelCostMap + get_model_cost_map()        │ litellm/litellm_core_utils/get_model_cost_map.py  │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ loadModelCostMap()  │ get_model_cost_map()                          │ litellm/litellm_core_utils/get_model_cost_map.py  │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ fetchRemote()       │ GetModelCostMap.fetch_remote_model_cost_map() │ litellm/litellm_core_utils/get_model_cost_map.py  │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ loadFromDiskCache() │ GetModelCostMap.load_local_model_cost_map()   │ litellm/litellm_core_utils/get_model_cost_map.py  │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ resolveModelEntry() │ model key resolution block in                 │ litellm/cost_calculator.py                        │
 │                     │ cost_per_token()                              │                                                   │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ computeCost()       │ generic_cost_per_token()                      │ litellm/litellm_core_utils/llm_cost_calc/utils.py │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ computeInputCost()  │ _calculate_input_cost()                       │ litellm/litellm_core_utils/llm_cost_calc/utils.py │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ computeOutputCost() │ output block in generic_cost_per_token()      │ litellm/litellm_core_utils/llm_cost_calc/utils.py │
 ├─────────────────────┼───────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ tieredRate()        │ threshold iteration in _get_token_base_cost() │ litellm/litellm_core_utils/llm_cost_calc/utils.py │
 └─────────────────────┴───────────────────────────────────────────────┴───────────────────────────────────────────────────┘
 ```
 
 ## How to use:
 ```
 ┌─────────────────────┬──────┬──────────┬────────────────────────────────────────────────────┐
 │        Field        │ Type │ Required │                    What to pass                    │
 ├─────────────────────┼──────┼──────────┼────────────────────────────────────────────────────┤
 │ promptTokens        │ Int  │ yes      │ input tokens from the API response                 │
 ├─────────────────────┼──────┼──────────┼────────────────────────────────────────────────────┤
 │ completionTokens    │ Int  │ yes      │ output tokens from the API response                │
 ├─────────────────────┼──────┼──────────┼────────────────────────────────────────────────────┤
 │ cacheReadTokens     │ Int  │ no       │ Anthropic cache_read_input_tokens                  │
 ├─────────────────────┼──────┼──────────┼────────────────────────────────────────────────────┤
 │ cacheCreationTokens │ Int  │ no       │ Anthropic cache_creation_input_tokens              │
 ├─────────────────────┼──────┼──────────┼────────────────────────────────────────────────────┤
 │ reasoningTokens     │ Int  │ no       │ Claude thinking / OpenAI o-series reasoning tokens │
 ├─────────────────────┼──────┼──────────┼────────────────────────────────────────────────────┤
 │ audioInputTokens    │ Int  │ no       │ audio input tokens if applicable                   │
 ├─────────────────────┼──────┼──────────┼────────────────────────────────────────────────────┤
 │ audioOutputTokens   │ Int  │ no       │ audio output tokens if applicable                  │
 └─────────────────────┴──────┴──────────┴────────────────────────────────────────────────────┘
 ```
 
 Provide the model name string — any of these forms work:
 - "claude-3-5-sonnet-20241022"
 - "anthropic/claude-3-5-sonnet-20241022"
 - "gpt-4o" (common providers are tried automatically)
                                                                                                                              
 ### Basic usage:
 ```
 let usage = RTSTokenUsage(promptTokens: 1500, completionTokens: 300)
                                                                                                                              
 let cost = try await RTSCostCalculator.shared.calculateCost(
     model: "claude-3-5-sonnet-20241022",
     usage: usage
 )
                                                                                                                              
 print(cost?.totalCost)      // total USD
 print(cost?.promptCost)     // input portion
 print(cost?.completionCost) // output portion
 ```
 
 With Anthropic prompt caching:
 ```
 let usage = RTSTokenUsage(
     promptTokens: 10_000,
     completionTokens: 500,
     cacheReadTokens: 8_000,    // from cache_read_input_tokens in API response
     cacheCreationTokens: 2_000 // from cache_creation_input_tokens
 )
                                                                                                                              
 let cost = try await RTSCostCalculator.shared.calculateCost(
     model: "anthropic/claude-3-5-sonnet-20241022",
     usage: usage
 )
 ```

 Returns nil if the model string isn't found in LiteLLM's pricing map. Throws RTSCostCalculatorError.noPricingDataAvailable
 only if both the network fetch and disk cache fail entirely (e.g. first run with no internet).
 */

// MARK: - Public Types

/// Token usage breakdown for a single LLM API call.
///
/// Mirrors LiteLLM's `Usage` type (`litellm/types/utils.py`).
public struct RTSTokenUsage: Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Tokens served from the provider's prompt cache (Anthropic cache_read_input_tokens, etc.)
    public var cacheReadTokens: Int
    /// Tokens written into the provider's prompt cache
    public var cacheCreationTokens: Int
    /// Reasoning tokens (Claude extended thinking, OpenAI o-series)
    public var reasoningTokens: Int
    public var audioInputTokens: Int
    public var audioOutputTokens: Int

    public init(
        promptTokens: Int,
        completionTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        reasoningTokens: Int = 0,
        audioInputTokens: Int = 0,
        audioOutputTokens: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.audioInputTokens = audioInputTokens
        self.audioOutputTokens = audioOutputTokens
    }
}

/// USD cost breakdown for a single LLM API call.
///
/// Mirrors the `(prompt_cost_in_usd, completion_cost_in_usd)` tuple returned by
/// `cost_per_token()` (`litellm/cost_calculator.py`).
public struct RTSTokenCost: Sendable {
    public let promptCost: Double
    public let completionCost: Double
    public var totalCost: Double { promptCost + completionCost }
}

public enum RTSCostCalculatorError: Error, LocalizedError {
    case remoteFetchFailed(statusCode: Int)
    case noPricingDataAvailable

    public var errorDescription: String? {
        switch self {
        case .remoteFetchFailed(let code):
            return "Remote pricing fetch returned HTTP \(code)"
        case .noPricingDataAvailable:
            return "No pricing data available: remote fetch failed and no disk-cached data exists"
        }
    }
}

// MARK: - RTSCostCalculator

/// Thread-safe actor mirroring LiteLLM's model pricing + cost calculation logic.
///
/// Mirrors `GetModelCostMap` class and `get_model_cost_map()` function
/// (`litellm/litellm_core_utils/get_model_cost_map.py`) for pricing fetch/fallback,
/// and `cost_per_token()` (`litellm/cost_calculator.py`) for cost calculation.
///
/// Pricing source (in priority order):
///   1. Remote JSON: https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
///   2. Disk cache (24-hour TTL) — used when the remote fetch fails, analogous to
///      LiteLLM's bundled `model_prices_and_context_window_backup.json` fallback.
public actor RTSCostCalculator {

    public static let shared = RTSCostCalculator()

    private static let remoteURLString = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    private static let cacheFileName = "litellm_model_prices_cache.json"
    private static let cacheTTL: TimeInterval = 86_400  // 24 hours

    private var modelCostMap: [String: [String: Any]]?
    private var modelCostMapLoadedAt: Date?

    private init() {}

    // MARK: - Public Interface

    /// Returns the USD cost for a model call, or `nil` if the model is not in the pricing map.
    public func calculateCost(model: String, usage: RTSTokenUsage) async throws -> RTSTokenCost? {
        let map = try await ensureModelCostMap()
        guard let entry = resolveModelEntry(model: model, in: map) else { return nil }
        return computeCost(entry: entry, usage: usage)
    }

    /// Discard in-memory and disk-cached data, then re-fetch from remote.
    public func refreshPricing() async throws {
        modelCostMap = nil
        try? FileManager.default.removeItem(at: cacheFileURL)
        modelCostMap = try await loadModelCostMap()
    }

    // MARK: - Pricing Map Loading

    private func ensureModelCostMap() async throws -> [String: [String: Any]] {
        if let existing = modelCostMap,
           let loadedAt = modelCostMapLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return existing
        }
        let map = try await loadModelCostMap()
        modelCostMap = map
        modelCostMapLoadedAt = Date()
        return map
    }

    /// Mirrors `get_model_cost_map()` (`litellm/litellm_core_utils/get_model_cost_map.py`).
    /// The LITELLM_LOCAL_MODEL_COST_MAP flag check is removed
    /// The updatd refresh mechanism as follow
    ///  1. Fetch fresh remote(fall back to disk cache if fail) price map at first use of every launch, store map in both disk and memory
    ///  2. Every cacheTTL(24h) duration, flush the in memory map and refetch remote(fall back to disk cache if failed)
    private func loadModelCostMap() async throws -> [String: [String: Any]] {
        do {
            let data = try await fetchRemote()
            let map = try parseJSON(data)
            saveToDiskCache(data)
            return map
        } catch {
            // Network failed — fall through to disk cache, ignoring TTL.
        }

        if let cachedData = loadFromDiskCache(respectTTL: true), let map = try? parseJSON(cachedData) {
            return map
        }

        throw RTSCostCalculatorError.noPricingDataAvailable
    }

    /// Mirrors `GetModelCostMap.fetch_remote_model_cost_map()` (`litellm/litellm_core_utils/get_model_cost_map.py`).
    private func fetchRemote() async throws -> Data {
        guard let url = URL(string: Self.remoteURLString) else {
            throw RTSCostCalculatorError.remoteFetchFailed(statusCode: -1)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RTSCostCalculatorError.remoteFetchFailed(statusCode: code)
        }
        return data
    }

    private func parseJSON(_ data: Data) throws -> [String: [String: Any]] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let dict = raw as? [String: Any] else {
            throw RTSCostCalculatorError.noPricingDataAvailable
        }
        // Entries that are not dictionaries (e.g. a top-level info string) are silently dropped.
        return dict.compactMapValues { $0 as? [String: Any] }
    }

    // MARK: - Disk Cache

    private var cacheFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.cacheFileName)
    }

    private func saveToDiskCache(_ data: Data) {
        log.debug("Saving cost map to local: \(cacheFileURL)")
        try? data.write(to: cacheFileURL)
    }

    /// Mirrors `GetModelCostMap.load_local_model_cost_map()` (`litellm/litellm_core_utils/get_model_cost_map.py`).
    /// Returns cached data only if the cache file is younger than `cacheTTL`.
    /// When used as a fallback after a network failure the TTL is intentionally
    /// ignored — any cached data is better than nothing (matching LiteLLM's
    /// "always use backup rather than fail" philosophy).
    private func loadFromDiskCache(respectTTL: Bool = true) -> Data? {
        let url = cacheFileURL
        if respectTTL {
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let modDate = attrs[.modificationDate] as? Date,
                Date().timeIntervalSince(modDate) < Self.cacheTTL
            else { return nil }
        }
        log.debug("Read local cost map from: \(cacheFileURL)")
        return try? Data(contentsOf: url)
    }

    // MARK: - Model Resolution

    /// Mirrors the model key resolution block inside `cost_per_token()` (`litellm/cost_calculator.py`).
    ///
    /// Three-step lookup:
    ///   1. Exact key as provided           e.g. "anthropic/claude-3-5-sonnet-20241022"
    ///   2. Key without leading provider/   e.g. "claude-3-5-sonnet-20241022"
    ///   3. Common provider prefixes added  e.g. "openai/gpt-4o" when caller passed "gpt-4o"
    private func resolveModelEntry(
        model: String,
        in map: [String: [String: Any]]
    ) -> [String: Any]? {
        if let entry = map[model] { return entry }

        let parts = model.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            let withoutPrefix = String(parts[1])
            if let entry = map[withoutPrefix] { return entry }
        }

        let commonProviders = [
            "anthropic", "openai", "google", "mistral", "cohere",
            "meta-llama", "bedrock", "vertex_ai", "azure",
            "groq", "together_ai", "fireworks_ai", "deepseek",
        ]
        for provider in commonProviders {
            if let entry = map["\(provider)/\(model)"] { return entry }
        }

        return nil
    }

    // MARK: - Cost Computation

    /// Mirrors `generic_cost_per_token()` (`litellm/litellm_core_utils/llm_cost_calc/utils.py`).
    private func computeCost(entry: [String: Any], usage: RTSTokenUsage) -> RTSTokenCost {
        let promptCost = computeInputCost(entry: entry, usage: usage)
        let completionCost = computeOutputCost(entry: entry, usage: usage)
        return RTSTokenCost(promptCost: promptCost, completionCost: completionCost)
    }

    /// Mirrors `_calculate_input_cost()` (`litellm/litellm_core_utils/llm_cost_calc/utils.py`).
    ///
    /// Input cost = text tokens × input_rate
    ///            + cache-read tokens × cache_read_rate
    ///            + cache-creation tokens × cache_creation_rate
    ///            + audio tokens × audio_input_rate
    private func computeInputCost(entry: [String: Any], usage: RTSTokenUsage) -> Double {
        let inputRate = tieredRate(
            entry: entry,
            baseKey: "input_cost_per_token",
            thresholdPrefix: "input_cost_per_token_above_",
            tokens: usage.promptTokens
        )
        let cacheReadRate = doubleValue(entry["cache_read_input_token_cost"]) ?? 0.0
        let cacheCreationRate = doubleValue(entry["cache_creation_input_token_cost"]) ?? 0.0
        let audioInputRate = doubleValue(entry["input_cost_per_audio_token"]) ?? inputRate

        // Non-cached, non-audio text tokens (avoids double-counting)
        let textTokens = max(
            0,
            usage.promptTokens
                - usage.cacheReadTokens
                - usage.cacheCreationTokens
                - usage.audioInputTokens
        )

        return Double(textTokens) * inputRate
            + Double(usage.cacheReadTokens) * cacheReadRate
            + Double(usage.cacheCreationTokens) * cacheCreationRate
            + Double(usage.audioInputTokens) * audioInputRate
    }

    /// Mirrors the output-cost block inside `generic_cost_per_token()` (`litellm/litellm_core_utils/llm_cost_calc/utils.py`).
    ///
    /// Output cost = text tokens × output_rate
    ///             + reasoning tokens × reasoning_rate   (falls back to output_rate)
    ///             + audio tokens × audio_output_rate     (falls back to output_rate)
    private func computeOutputCost(entry: [String: Any], usage: RTSTokenUsage) -> Double {
        // LiteLLM selects the output tier based on prompt_tokens (context size), not completion_tokens.
        let outputRate = tieredRate(
            entry: entry,
            baseKey: "output_cost_per_token",
            thresholdPrefix: "output_cost_per_token_above_",
            tokens: usage.promptTokens
        )
        let reasoningRate = doubleValue(entry["output_cost_per_reasoning_token"]) ?? outputRate
        let audioOutputRate = doubleValue(entry["output_cost_per_audio_token"]) ?? outputRate

        let hasBreakdown = usage.reasoningTokens > 0 || usage.audioOutputTokens > 0
        let textTokens: Int
        if hasBreakdown {
            textTokens = max(
                0,
                usage.completionTokens - usage.reasoningTokens - usage.audioOutputTokens
            )
        } else {
            textTokens = usage.completionTokens
        }

        return Double(textTokens) * outputRate
            + Double(usage.reasoningTokens) * reasoningRate
            + Double(usage.audioOutputTokens) * audioOutputRate
    }

    // MARK: - Tiered Rate Resolution

    /// Mirrors the threshold-key iteration inside `_get_token_base_cost()` (`litellm/litellm_core_utils/llm_cost_calc/utils.py`).
    ///
    /// Returns the effective cost-per-token, applying the highest exceeded threshold tier.
    /// LiteLLM stores tiered keys as e.g. `input_cost_per_token_above_128k_tokens`.
    /// We iterate thresholds highest-first and return the first rate whose threshold
    /// `tokens` exceeds. Falls back to `baseKey` if no threshold is exceeded.
    private func tieredRate(
        entry: [String: Any],
        baseKey: String,
        thresholdPrefix: String,
        tokens: Int
    ) -> Double {
        let thresholds: [(threshold: Int, suffix: String)] = [
            (272_000, "272k_tokens"),
            (200_000, "200k_tokens"),
            (128_000, "128k_tokens"),
        ]
        for (threshold, suffix) in thresholds {
            let key = "\(thresholdPrefix)\(suffix)"
            if tokens > threshold, let rate = doubleValue(entry[key]) {
                return rate
            }
        }
        return doubleValue(entry[baseKey]) ?? 0.0
    }

    // MARK: - Helpers

    /// Coerces Any? (Double, Float, Int, String) to Double.
    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let f as Float:  return Double(f)
        case let i as Int:    return Double(i)
        case let s as String: return Double(s)
        default:              return nil
        }
    }
}
