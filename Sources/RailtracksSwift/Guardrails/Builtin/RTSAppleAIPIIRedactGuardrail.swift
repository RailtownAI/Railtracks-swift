//
//  RTSAppleAIPIIRedactGuardrail.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-29.
//
//  A model-based PII redaction guardrail using Apple's on-device LLM
//  (FoundationModels). Complements the regex `RTSPIIRedact*Guardrail` by catching
//  unstructured PII that regex cannot — names, addresses, name-revealing handles,
//  etc. Emits the same trace format (`[LABEL]` placeholders + `redacted_entities`).

import Foundation
import FoundationModels

// MARK: - Structured output

/// Detected PII spans, as two parallel arrays. (Flat string arrays rather than an
/// array of a nested `@Generable` struct, which the macro can't express here.)
@available(macOS 26, iOS 26, *)
@Generable
struct RTSDetectedPIIList {
    @Guide(description: "Each exact PII text span found in the input, copied character-for-character. Empty if none.")
    var values: [String]
    @Guide(description: "The kind of each span in `values`, in the SAME order and count. Concise SCREAMING_SNAKE_CASE, e.g. PERSON_NAME, EMAIL, ADDRESS.")
    var labels: [String]
}

// MARK: - Engine

@available(macOS 26, iOS 26, *)
enum RTSAppleAIPIIEngine {

    static let systemPrompt = """
    You are an expert at identifying personally identifiable information (PII) in arbitrary text. \
    Identify ALL instances of PII that should be anonymized for privacy protection.

    CRITICAL: Extract the EXACT text strings as they appear in the input — copy them \
    character-for-character, do not paraphrase or modify them, so they can be located and \
    replaced precisely.

    Identify these types of PII:
    - Personal names of ANY individual mentioned, not only the author or main subject but also third \
    parties such as colleagues, managers, references, friends, or family. Redact every human name \
    (first, last, or full) regardless of whose it is or their relationship to the author.
    - Email addresses
    - Phone numbers (mobile, home, work)
    - Physical/mailing addresses (street addresses, postal/ZIP codes, and cities when uncommon enough to be identifying)
    - Personal URLs, portfolios, or profile links that contain or reveal a name (e.g. LinkedIn, personal sites)
    - Account usernames or handles that reveal a real name (e.g. GitHub/GitLab)
    - Government or financial identifiers (SSN, SIN, passport, credit card, bank/IBAN numbers)
    - Dates tied to an individual (e.g. date of birth)
    - Any other uniquely identifying information

    Avoid over-redaction. Do not redact text that does not identify a specific individual — \
    generic terms, common words, organization or company names, and general descriptions. \
    Redact only genuine personal identifiers and sensitive personal data. When unsure whether \
    something identifies a specific person, prefer to redact it.

    For each piece of PII found:
    1. Provide the exact value exactly as it appears in the input.
    2. Assign a concise SCREAMING_SNAKE_CASE label (e.g. PERSON_NAME, EMAIL, PHONE, ADDRESS, LOCATION, LINKEDIN_URL, SSN, DATE_OF_BIRTH).

    Names of people other than the author — referrals, coworkers, and people mentioned only in \
    passing — are still PII and MUST be redacted. Do not skip a name just because it is not the author's.

    Be thorough — missing PII defeats the purpose. Do not invent PII that is not present.
    """

    /// Detects and redacts PII in `text` using the on-device model.
    ///
    /// This guardrail calls the on-device model directly, not through RailtracksSwift's
    /// gateway/flow, for two privacy reasons:
    ///  1. On-device detection — the text is scanned for PII locally and is never sent to a
    ///     network/cloud provider just to detect it.
    ///  2. Not traced — routing it through the flow would record this detection call as a node
    ///     whose recorded input is the RAW, un-redacted text, persisting the very PII we're
    ///     removing into the JSON report. Calling directly keeps that raw input out of the trace.
    /// The model still receives the text (it must, to detect PII); only the *recording* of that
    /// raw input is avoided. The guardrail's verdict (labels + counts via `guard_details`) and
    /// the redacted result are still traced normally.
    ///
    /// Returns the redacted text and the (normalized) label of each redacted span.
    /// - Throws: `RTSError.providerUnavailable` when the on-device model is unavailable
    ///   (fail-closed — never silently pass PII through), or any error the model raises.
    static func redact(_ text: String) async throws -> (redacted: String, hits: [String]) {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw RTSError.providerUnavailable(
                "On-device model unavailable for PII redaction: \(reason)"
            )
        @unknown default:
            throw RTSError.providerUnavailable("On-device model availability is unknown.")
        }

        let session = LanguageModelSession(instructions: systemPrompt)
        let content = try await session.respond(
            to: text,
            generating: RTSDetectedPIIList.self
        ).content
        let values = content.values
        guard !values.isEmpty else { return (text, []) }
        let labels = content.labels

        // Pair each value with its label by position; default to "PII" if the model
        // under-supplied labels (so a detected span is never left un-redacted).
        // Replace longest values first so a short span that is a substring of a longer
        // one doesn't redact partially.
        let pairs = values.enumerated()
            .map { (value: $1, label: $0 < labels.count ? labels[$0] : "PII") }
            .sorted { $0.value.count > $1.value.count }

        var redacted = text
        var hits: [String] = []
        for pair in pairs {
            guard !pair.value.isEmpty, redacted.contains(pair.value) else { continue }
            let label = normalizeLabel(pair.label)
            let occurrences = redacted.components(separatedBy: pair.value).count - 1
            redacted = redacted.replacingOccurrences(of: pair.value, with: "[\(label)]")
            hits.append(contentsOf: Array(repeating: label, count: occurrences))
        }
        return (redacted, hits)
    }

    /// Normalizes a model-supplied label to a `[SCREAMING_SNAKE_CASE]`-friendly token.
    static func normalizeLabel(_ raw: String) -> String {
        let mapped = raw.uppercased().map { ($0.isLetter || $0.isNumber) ? $0 : "_" }
        var s = String(mapped)
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "PII" : s
    }

    /// Builds the redaction trace metadata, matching the regex guard's shape.
    static func metadata(counts: [String: Int], keysAffected: Int) -> [String: RTSValue] {
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
}

// MARK: - Guardrails

/// Input guardrail that redacts PII from the inspected input values using Apple's
/// on-device model before they reach the LLM.
///
/// Throws if the on-device model is unavailable (fail-closed), so it should only be
/// attached for runs on devices with Apple Intelligence available.
@available(macOS 26, iOS 26, *)
public struct RTSAppleAIPIIRedactInputGuardrail: RTSAgentInputGuardrail {
    public let name: String
    public let keys: [String]

    public init(
        keys: [String] = ["prompt"],
        name: String = "AppleAIPIIRedactInputGuard"
    ) {
        self.keys = keys
        self.name = name
    }

    public func check(_ input: RTSInput) async throws -> RTSInputGuardrailResult {
        var newInput = input
        var counts: [String: Int] = [:]
        var keysAffected = 0
        for key in keys {
            guard case let .string(s)? = input[key] else { continue }
            let (redacted, hits) = try await RTSAppleAIPIIEngine.redact(s)
            if !hits.isEmpty {
                newInput[key] = .string(redacted)
                keysAffected += 1
                for label in hits { counts[label, default: 0] += 1 }
            }
        }
        guard !counts.isEmpty else { return .allow("No PII detected in input (on-device).") }
        let total = counts.values.reduce(0, +)
        return .transform(
            newInput,
            reason: "Redacted \(total) PII span(s) from input (on-device).",
            metadata: RTSAppleAIPIIEngine.metadata(counts: counts, keysAffected: keysAffected)
        )
    }
}

/// Output guardrail that redacts PII from the inspected output values using Apple's
/// on-device model before they are returned to the caller.
@available(macOS 26, iOS 26, *)
public struct RTSAppleAIPIIRedactOutputGuardrail: RTSAgentOutputGuardrail {
    public let name: String
    public let keys: [String]

    public init(
        keys: [String] = ["result"],
        name: String = "AppleAIPIIRedactOutputGuard"
    ) {
        self.keys = keys
        self.name = name
    }

    public func check(_ output: RTSOutput) async throws -> RTSOutputGuardrailResult {
        var newOutput = output
        var counts: [String: Int] = [:]
        var keysAffected = 0
        for key in keys {
            guard case let .string(s)? = output[key] else { continue }
            let (redacted, hits) = try await RTSAppleAIPIIEngine.redact(s)
            if !hits.isEmpty {
                newOutput[key] = .string(redacted)
                keysAffected += 1
                for label in hits { counts[label, default: 0] += 1 }
            }
        }
        guard !counts.isEmpty else { return .allow("No PII detected in output (on-device).") }
        let total = counts.values.reduce(0, +)
        return .transform(
            newOutput,
            reason: "Redacted \(total) PII span(s) from output (on-device).",
            metadata: RTSAppleAIPIIEngine.metadata(counts: counts, keysAffected: keysAffected)
        )
    }
}
