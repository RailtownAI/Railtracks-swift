//
//  RTSPIIRedactGuardrail.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-29.
//
//  Port of the Python `guardrails/llm/_pii` engine and redaction guards.

import Foundation

// MARK: - Config

/// Built-in PII entity kinds with reliable regex detection.
/// The raw value is the trace label and placeholder name (e.g. `[EMAIL_ADDRESS]`).
/// This does not covers all PII, only ones that are easily recognized through regex pattern
public enum RTSPIIEntity: String, Sendable, CaseIterable, Hashable {
    case email      = "EMAIL_ADDRESS"
    case phone      = "PHONE_NUMBER"
    case creditCard = "CREDIT_CARD"
    case usSSN      = "US_SSN"
    case caSIN      = "CA_SIN"
    case ipAddress  = "IP_ADDRESS"
    case url        = "URL"
    case iban       = "IBAN_CODE"
}

/// A user-defined PII pattern. `name` becomes the placeholder label, e.g.
/// `"EMPLOYEE_ID"` yields `[EMPLOYEE_ID]` in redacted text.
public struct RTSPIICustomPattern: Sendable, Hashable {
    public let name: String
    public let regex: String

    public init(name: String, regex: String) {
        self.name = name
        self.regex = regex
    }
}

/// Configuration for the PII redaction guardrails.
public struct RTSPIIRedactConfig: Sendable {
    /// Built-in entity kinds to detect. Defaults to all.
    public let entities: [RTSPIIEntity]
    /// Extra user-defined patterns, merged into detection after the built-ins.
    public let customPatterns: [RTSPIICustomPattern]

    public init(
        entities: [RTSPIIEntity] = RTSPIIEntity.allCases,
        customPatterns: [RTSPIICustomPattern] = []
    ) {
        self.entities = entities
        self.customPatterns = customPatterns
    }
}

// MARK: - Engine

/// Regex-based PII detection and redaction. Built transiently inside `check`
/// (its compiled `Regex`es are not stored on the `Sendable` guardrail).
struct RTSPIIEngine {
    private struct Compiled {
        let regex: NSRegularExpression
        let entityType: String
        let placeholder: String
        let luhn: Bool
    }

    private let patterns: [Compiled]

    /// - Throws: if any built-in or custom pattern fails to compile.
    init(config: RTSPIIRedactConfig) throws {
        var compiled: [Compiled] = []
        let enabled = Set(config.entities)
        // Built-in patterns kept in precedence order (earlier wins on overlap).
        for (entity, raw) in Self.builtinPatterns where enabled.contains(entity) {
            compiled.append(Compiled(
                regex: try NSRegularExpression(pattern: raw),
                entityType: entity.rawValue,
                placeholder: "[\(entity.rawValue)]",
                luhn: Self.luhnValidated.contains(entity)
            ))
        }
        for custom in config.customPatterns {
            compiled.append(Compiled(
                regex: try NSRegularExpression(pattern: custom.regex),
                entityType: custom.name,
                placeholder: "[\(custom.name)]",
                luhn: false
            ))
        }
        self.patterns = compiled
    }

    /// Replaces detected spans with placeholders, merging overlaps by priority.
    /// Returns the redacted string and the entity type of each redacted span.
    func redact(_ text: String) -> (redacted: String, hits: [String]) {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var spans: [Span] = []
        for (priority, p) in patterns.enumerated() {
            for match in p.regex.matches(in: text, range: fullRange) {
                guard let range = Range(match.range, in: text) else { continue }
                if p.luhn {
                    let digits = String(text[range].filter(\.isNumber))
                    guard Self.passesLuhn(digits) else { continue }
                }
                spans.append(Span(
                    range: range,
                    length: text.distance(from: range.lowerBound, to: range.upperBound),
                    entityType: p.entityType,
                    placeholder: p.placeholder,
                    priority: priority
                ))
            }
        }
        guard !spans.isEmpty else { return (text, []) }

        let merged = Self.mergeSpans(spans)
        var result = ""
        var cursor = text.startIndex
        var hits: [String] = []
        for span in merged {
            result += text[cursor..<span.range.lowerBound]
            result += span.placeholder
            hits.append(span.entityType)
            cursor = span.range.upperBound
        }
        result += text[cursor...]
        return (result, hits)
    }

    private struct Span {
        let range: Range<String.Index>
        let length: Int
        let entityType: String
        let placeholder: String
        let priority: Int
    }

    /// Sort by start, then priority (lower = higher priority). On overlap keep the
    /// higher-priority span; break ties by length.
    private static func mergeSpans(_ spans: [Span]) -> [Span] {
        let sorted = spans.sorted {
            $0.range.lowerBound != $1.range.lowerBound
                ? $0.range.lowerBound < $1.range.lowerBound
                : $0.priority < $1.priority
        }
        var merged: [Span] = []
        for span in sorted {
            if let prev = merged.last, span.range.lowerBound < prev.range.upperBound {
                if span.priority < prev.priority {
                    merged[merged.count - 1] = span
                } else if span.priority == prev.priority, span.length > prev.length {
                    merged[merged.count - 1] = span
                }
                // otherwise keep `prev`
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Luhn (mod 10) checksum over decimal digits — cuts false positives on
    /// credit-card and Canadian SIN patterns.
    private static func passesLuhn(_ digits: String) -> Bool {
        guard !digits.isEmpty else { return false }
        var total = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var n = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                n *= 2
                if n > 9 { n -= 9 }
            }
            total += n
        }
        return total % 10 == 0
    }

    private static let luhnValidated: Set<RTSPIIEntity> = [.creditCard, .caSIN]

    /// Insertion order defines overlap precedence (earlier wins). Copied verbatim
    /// from the Python `_BUILTIN_PATTERNS`.
    private static let builtinPatterns: [(RTSPIIEntity, String)] = [
        (.email, #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#),
        (.url, #"https?://[^\s<>"']+"#),
        (.creditCard, #"\b(?:\d[ \-]?){13,16}\b"#),
        (.iban, #"\b[A-Z]{2}\d{2}[\s]?[\dA-Z]{4}[\s]?(?:[\dA-Z]{4}[\s]?){1,7}[\dA-Z]{1,4}\b"#),
        (.usSSN, #"\b\d{3}-\d{2}-\d{4}\b"#),
        (.caSIN, #"\b\d{3}-\d{3}-\d{3}\b"#),
        (.ipAddress, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
        (.phone, #"(?<![.\d/])(?:\+\d{1,3}[\s\-.]?)?(?:\(?\d{3}\)?[\s\-.]?)?\d{3}[\s\-.]?\d{4}(?!\d)(?!\.\d)"#),
    ]
}

// MARK: - Meta

private func buildRedactionMeta(counts: [String: Int], keysAffected: Int) -> [String: RTSValue] {
    [
        "redacted_entities": .array(counts.map { entityType, count in
            .object([
                "entity_type": .string(entityType),
                "count": .number(Double(count)),
            ])
        }),
        "keys_affected": .number(Double(keysAffected)),
    ]
}

// MARK: - Guardrails

/// Input guardrail that redacts PII from the inspected input values before they
/// reach the LLM. Mirrors the Python `PIIRedactInputGuard`.
public struct RTSPIIRedactInputGuardrail: RTSAgentInputGuardrail {
    public let name: String
    public let keys: [String]
    public let config: RTSPIIRedactConfig

    /// - Throws: if any built-in or custom pattern fails to compile (fail-fast).
    public init(
        name: String = "PIIRedactInputGuard",
        keys: [String] = ["prompt"],
        config: RTSPIIRedactConfig = .init()
    ) throws {
        _ = try RTSPIIEngine(config: config)
        self.config = config
        self.keys = keys
        self.name = name
    }

    public func check(_ input: RTSInput) async throws -> RTSInputGuardrailResult {
        let engine = try RTSPIIEngine(config: config)
        var newInput = input
        var counts: [String: Int] = [:]
        var keysAffected = 0
        // TODO: only top-level `.string` values at `keys` are scanned. Consider
        // recursing into nested `.object` / `.array` values to catch PII in
        // structured inputs (e.g. sub-agent arguments).
        for key in keys {
            guard case let .string(s)? = input[key] else { continue }
            let (redacted, hits) = engine.redact(s)
            if !hits.isEmpty {
                newInput[key] = .string(redacted)
                keysAffected += 1
                for entity in hits { counts[entity, default: 0] += 1 }
            }
        }
        guard !counts.isEmpty else { return .allow("No PII detected in input.") }
        let total = counts.values.reduce(0, +)
        return .transform(
            newInput,
            reason: "Redacted \(total) PII span(s) from input.",
            metadata: buildRedactionMeta(counts: counts, keysAffected: keysAffected)
        )
    }
}

/// Output guardrail that redacts PII from the inspected output values before they
/// are returned to the caller. Mirrors the Python `PIIRedactOutputGuard`.
public struct RTSPIIRedactOutputGuardrail: RTSAgentOutputGuardrail {
    public let name: String
    public let keys: [String]
    public let config: RTSPIIRedactConfig

    /// - Throws: if any built-in or custom pattern fails to compile (fail-fast).
    public init(
        name: String = "PIIRedactOutputGuard",
        keys: [String] = ["result"],
        config: RTSPIIRedactConfig = .init()
    ) throws {
        _ = try RTSPIIEngine(config: config)
        self.config = config
        self.keys = keys
        self.name = name
    }

    public func check(_ output: RTSOutput) async throws -> RTSOutputGuardrailResult {
        let engine = try RTSPIIEngine(config: config)
        var newOutput = output
        var counts: [String: Int] = [:]
        var keysAffected = 0
        // TODO: only top-level `.string` values at `keys` are scanned. Consider
        // recursing into nested `.object` / `.array` values to catch PII in
        // structured outputs.
        for key in keys {
            guard case let .string(s)? = output[key] else { continue }
            let (redacted, hits) = engine.redact(s)
            if !hits.isEmpty {
                newOutput[key] = .string(redacted)
                keysAffected += 1
                for entity in hits { counts[entity, default: 0] += 1 }
            }
        }
        guard !counts.isEmpty else { return .allow("No PII detected in output.") }
        let total = counts.values.reduce(0, +)
        return .transform(
            newOutput,
            reason: "Redacted \(total) PII span(s) from output.",
            metadata: buildRedactionMeta(counts: counts, keysAffected: keysAffected)
        )
    }
}
