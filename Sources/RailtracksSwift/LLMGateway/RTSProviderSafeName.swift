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

    /// Prefix used when a name has nothing decodable in it at all.
    static let fallback = "unnamed"

    /// Reserved for the uniqueness suffix appended when a name is too long to encode in full:
    /// `_h` plus 6 hex characters.
    private static let uniquenessSuffixLength = 8

    /// Rewrites `name` into a provider-accepted identifier, preserving as much of the authored name as
    /// the rules allow: legal ASCII passes through, illegal ASCII (space, dot, colon, control
    /// characters) becomes `_`, and every non-ASCII character becomes a fixed-width `_uXXXX` escape of
    /// its UTF-16 code unit — the same convention JSON uses.
    ///
    /// Escaping rather than flattening non-ASCII keeps the authored name *recoverable*: the provider
    /// echoes this identifier back in its tool calls, and it lands in the trace's message log, so a
    /// reader can decode `_u5199_u771F_u691C_u7D22` back to `写真検索` with no lookup table. A run of
    /// underscores would have thrown that away, and two different names could collide on it.
    ///
    /// | Authored | Provider-facing | Why |
    /// |---|---|---|
    /// | `Photo Summary Search` | `Photo_Summary_Search` | space is illegal |
    /// | `photo.search:v2` | `photo_search_v2` | legal on Gemini, illegal on OpenAI/Anthropic |
    /// | `2fa check` | `_2fa_check` | cannot start with a digit |
    /// | `get-weather` | `get-weather` | already legal — unchanged |
    /// | `Fotoübersicht` | `Foto_u00FCbersicht` | non-ASCII escaped in place |
    /// | `写真検索` | `_u5199_u771F_u691C_u7D22` | fully decodable |
    /// | `🎉` | `_uD83C_uDF89` | astral scalar emits its surrogate pair |
    /// | 18 CJK characters | first 9 escapes + `_h238910` | too long: prefix kept, hash keeps it unique |
    /// | `""`, `"  "`, `"..."` | `unnamed_<hash>` | nothing to decode, so a hash keeps them distinct |
    ///
    /// The name is normalized to NFC before encoding, so the precomposed and decomposed spellings of
    /// one visible name produce one identifier rather than two. Truncation only ever cuts between whole
    /// tokens — a split `_uXXXX` would silently decode to the wrong character.
    ///
    /// Known limitation: a name authored as the literal ASCII text `foo_u5199bar` encodes to itself and
    /// is therefore indistinguishable from `foo写bar` when decoding. Preventing that would mean escaping
    /// every literal `_` (turning `Photo_Summary_Search` into `Photo__Summary__Search`), which costs far
    /// more than the ambiguity is worth.
    static func sanitized(_ name: String) -> String {
        // NFC first: escapes expose normalization that grapheme-cluster comparison hid, so "ü" and
        // "u" + combining diaeresis must not encode differently — otherwise one visible name reaches
        // the provider as two different identifiers.
        let normalized = name.precomposedStringWithCanonicalMapping
        var tokens: [String] = []
        var hasRecoverableContent = false
        for unit in normalized.utf16 {
            if unit < 0x80 {
                let character = Character(UnicodeScalar(UInt8(unit)))
                if allowedCharacters.contains(character) {
                    tokens.append(String(character))
                    if character != "_", character != "-" {
                        hasRecoverableContent = true
                    }
                } else {
                    // Illegal ASCII becomes "_": the substitution is self-evident to a reader, so an
                    // escape would cost length without adding clarity.
                    tokens.append("_")
                }
            } else {
                tokens.append(String(format: "_u%04X", unit))
                hasRecoverableContent = true
            }
        }
        guard hasRecoverableContent else {
            // Only separators survived (an all-punctuation or empty name); there is nothing to decode,
            // so a hash keeps such names distinct from one another.
            return "\(fallback)_\(RailtracksSwift.equalityHash(normalized).prefix(8))"
        }
        // Providers require the first character to be a letter or an underscore.
        if let first = tokens.first?.first, !(first.isLetter || first == "_") {
            tokens.insert("_", at: 0)
        }
        let encoded = tokens.joined()
        if encoded.count <= maxLength {
            return encoded
        }
        // Too long: keep whole tokens only, and spend the last characters on a hash of the full name so
        // two names sharing a prefix stay distinct.
        var truncated = ""
        for token in tokens {
            if truncated.count + token.count > maxLength - uniquenessSuffixLength {
                break
            }
            truncated += token
        }
        return "\(truncated)_h\(RailtracksSwift.equalityHash(normalized).prefix(6))"
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
