//
//  RTSProviderSafeName.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-08-12.
//

import Foundation

/// Rewrites an authored Railtracks name into an identifier every supported LLM provider accepts.
///
/// Railtracks lets a tool or an agent carry a human-readable name, but providers treat the function
/// names they receive as identifiers and reject the entire request otherwise. Gemini fails with
/// `GenerateContentRequest.tools[0].function_declarations[0].name: Invalid function name` for a tool
/// named `Photo Summary Search`; OpenAI and Anthropic enforce the same shape,
/// `^[a-zA-Z0-9_-]{1,64}$`, which is stricter still — it rejects the dots and colons Gemini allows.
///
/// Sanitizing happens at the provider boundary (the tool bridges) only. The authored `toolName` /
/// `agentName` remains what the flow graph trace, the visualizer, and the evaluation reports show,
/// so a readable agent name stays readable everywhere a human reads it.
enum RTSProviderSafeName {
    /// Shortest limit across supported providers — OpenAI and Anthropic cap function names at 64
    /// characters, Gemini at 128.
    static let maxLength = 64

    /// Intersection of the character sets accepted by OpenAI, Anthropic, and Gemini.
    private static let allowedCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    /// Prefix used when no character of the authored name survives sanitizing.
    static let fallback = "unnamed"

    /// Replaces every disallowed character with `_`, one for one, so `"Photo Summary Search"` becomes
    /// `"Photo_Summary_Search"` — the same form users reach for when the authored name is rejected.
    ///
    /// Names written in a non-Latin script are rejected by every provider (the accepted set is ASCII
    /// only), and replacing them character by character would yield a meaningless run of underscores
    /// that two different names could collide on. Those fall back to `unnamed_<hash prefix>`, which is
    /// unique and stable per authored name — the tool's description, which providers do not restrict,
    /// still carries the original wording to the model.
    static func sanitized(_ name: String) -> String {
        var result = ""
        result.reserveCapacity(name.count)
        var containsAlphanumeric = false
        for character in name {
            guard allowedCharacters.contains(character) else {
                result.append("_")
                continue
            }
            result.append(character)
            if character != "_", character != "-" {
                containsAlphanumeric = true
            }
        }
        guard containsAlphanumeric, let first = result.first else {
            return "\(fallback)_\(RailtracksSwift.equalityHash(name).prefix(8))"
        }
        // Providers require the first character to be a letter or an underscore.
        if !(first.isLetter || first == "_") {
            result = "_" + result
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        return result
    }

    /// Warns about the rewrites and collisions `sanitized(_:)` introduces for one agent's tool set,
    /// showing each authored name next to the name that replaces it, so a rewrite is visible rather
    /// than silently applied.
    static func logRewrites(of authoredNames: [String], agentName: String) {
        let rewrites = authoredNames
            .map { (authored: $0, providerFacing: sanitized($0)) }
            .filter { $0.authored != $0.providerFacing }
        if !rewrites.isEmpty {
            let described = rewrites.map { "'\($0.authored)' → '\($0.providerFacing)'" }
            log.warning("⚠️ [\(agentName)] tool name(s) rewritten to satisfy provider naming rules: \(described)")
        }
        let collisions = Dictionary(grouping: authoredNames, by: { sanitized($0) })
            .filter { $0.value.count > 1 }
        for (providerFacing, authored) in collisions {
            log.warning("⚠️ [\(agentName)] tool names \(authored) all map to '\(providerFacing)' — the LLM cannot tell them apart")
        }
    }
}
