//
//  ProviderSafeNameTests.swift
//  RailtracksSwiftTests
//
//  Verifies that names sent to a provider as function identifiers are sanitized at the bridge, while
//  the authored name is left untouched for tracing. Reported as a Gemini failure: a tool named
//  "Photo Summary Search" rejects the whole request with `Invalid function name`.
//

import Testing
import Foundation
@testable import RailtracksSwift

/// Tool whose name is supplied by the test.
private struct StubTool: RTSToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName: String
    let toolDescription = "stub tool"
    let parameterSchema = RTSToolSchema(parameters: [])
    let callableRoutine = RTSClosure { _ in [:] }
}

/// Reverses `RTSProviderSafeName`'s `_uXXXX` escapes, standing in for whatever reads a trace and wants
/// the authored name back. Deliberately a separate implementation, not a call into the library, so the
/// encoding is pinned by an independent decoder rather than by its own inverse.
private func decodeEscapes(_ encoded: String) -> String {
    var units: [UInt16] = []
    var rest = Substring(encoded)
    while let escape = rest.range(of: "_u") {
        units.append(contentsOf: Array(rest[rest.startIndex..<escape.lowerBound].utf16))
        let hexStart = escape.upperBound
        guard
            let hexEnd = rest.index(hexStart, offsetBy: 4, limitedBy: rest.endIndex),
            let unit = UInt16(rest[hexStart..<hexEnd], radix: 16)
        else {
            // Not a well-formed escape — keep it literally and stop.
            units.append(contentsOf: Array(rest.utf16))
            return String(decoding: units, as: UTF16.self)
        }
        units.append(unit)
        rest = rest[hexEnd...]
    }
    units.append(contentsOf: Array(rest.utf16))
    return String(decoding: units, as: UTF16.self)
}

/// The rule every supported provider's function name must satisfy: first character a letter or an
/// underscore, remainder `[A-Za-z0-9_-]`, at most 64 characters. This is the intersection of the
/// OpenAI/Anthropic pattern `^[a-zA-Z0-9_-]{1,64}$` and Gemini's (looser) rule.
private func isAcceptedByProviders(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 64 else {
        return false
    }
    guard let first = name.first, first.isASCII, first.isLetter || first == "_" else {
        return false
    }
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    return name.allSatisfy { allowed.contains($0) }
}

extension RailtracksSwiftTestSuite {
    @Suite("Provider-safe tool names")
    struct ProviderSafeNameTests {

        // MARK: - sanitizer

        @Test("Spaces become underscores — the form users already work around with")
        func spacesBecomeUnderscores() {
            #expect(RTSProviderSafeName.sanitized("Photo Summary Search") == "Photo_Summary_Search")
        }

        @Test("Already-legal names pass through untouched")
        func legalNamesUnchanged() {
            for name in ["Photo_Summary_Search", "get-weather", "tool123", "_private"] {
                #expect(RTSProviderSafeName.sanitized(name) == name)
            }
        }

        @Test("Dots and colons are replaced — Gemini allows them but OpenAI and Anthropic do not")
        func dotsAndColonsReplaced() {
            #expect(RTSProviderSafeName.sanitized("photo.search:v2") == "photo_search_v2")
        }

        @Test("A leading digit is prefixed with an underscore")
        func leadingDigitPrefixed() {
            #expect(RTSProviderSafeName.sanitized("2fa check") == "_2fa_check")
        }

        @Test("A leading dash is prefixed — legal character, illegal position")
        func leadingDashPrefixed() {
            #expect(RTSProviderSafeName.sanitized("-tool") == "_-tool")
        }

        @Test("Accented Latin is escaped in place")
        func accentedLatinSanitized() {
            #expect(RTSProviderSafeName.sanitized("Fotoübersicht") == "Foto_u00FCbersicht")
            #expect(RTSProviderSafeName.sanitized("Résumé Parser") == "R_u00E9sum_u00E9_Parser")
        }

        @Test("Non-Latin scripts are escaped, not flattened or hashed")
        func nonLatinScriptsAreEscaped() {
            let japanese = RTSProviderSafeName.sanitized("写真検索")
            #expect(japanese == "_u5199_u771F_u691C_u7D22")
            #expect(isAcceptedByProviders(japanese))
            // Same authored name always yields the same identifier.
            #expect(RTSProviderSafeName.sanitized("写真検索") == japanese)
            // Two equal-length names of the same script must not collide, which a naive
            // character-for-character replacement would ("____" for both).
            #expect(RTSProviderSafeName.sanitized("写真要約") != japanese)
        }

        @Test("A mixed-script name keeps its ASCII and escapes the rest")
        func mixedScriptNameEscapesOnlyNonASCII() {
            // An escape carries its own leading `_` and no trailing one, so the space contributes the
            // single separator before "Search" rather than doubling it.
            #expect(RTSProviderSafeName.sanitized("写真 Search") == "_u5199_u771F_Search")
        }

        @Test("An escaped name decodes back to what was authored")
        func escapedNamesRoundTrip() {
            // The point of escaping over flattening: the identifier the provider echoes into the trace
            // can be read back without a lookup table.
            for authored in ["写真検索", "Fotoübersicht", "🎉", "Ελληνικά", "Резюме", "写真-検索_v2"] {
                let sanitized = RTSProviderSafeName.sanitized(authored)
                #expect(decodeEscapes(sanitized) == authored, "'\(authored)' did not round-trip")
            }
        }

        @Test("Illegal ASCII is not recoverable — only non-ASCII is escaped")
        func illegalASCIIIsNotRecoverable() {
            // Spaces, dots and colons become `_` by design: the substitution is self-evident, so it is
            // not worth 6 characters of budget each. Decoding therefore returns the `_` form.
            #expect(decodeEscapes(RTSProviderSafeName.sanitized("写真 Search")) == "写真_Search")
        }

        @Test("Decomposed and precomposed spellings yield the same identifier")
        func unicodeNormalizationIsStable() {
            // "Fotoübersicht" with a precomposed U+00FC vs. u + U+0308 combining diaeresis. Escapes are
            // per UTF-16 unit, so without the NFC pass these would encode differently and one visible
            // name would reach the provider under two identifiers.
            let precomposed = "Foto\u{00FC}bersicht"
            let decomposed = "Fotou\u{0308}bersicht"
            #expect(precomposed.unicodeScalars.count != decomposed.unicodeScalars.count)
            #expect(RTSProviderSafeName.sanitized(precomposed) == RTSProviderSafeName.sanitized(decomposed))
            #expect(RTSProviderSafeName.sanitized(decomposed) == "Foto_u00FCbersicht")
        }

        @Test("A multi-scalar emoji escapes every scalar and still round-trips")
        func zeroWidthJoinerEmojiIsEscaped() {
            // Family emoji: one grapheme cluster, five scalars joined by ZWJ.
            let sanitized = RTSProviderSafeName.sanitized("photo 👨‍👩‍👧 tool")
            #expect(isAcceptedByProviders(sanitized))
            #expect(decodeEscapes(sanitized) == "photo 👨‍👩‍👧 tool".replacingOccurrences(of: " ", with: "_"))
        }

        @Test("Emoji-only and empty names are still legal identifiers")
        func degenerateNamesAreLegal() {
            #expect(isAcceptedByProviders(RTSProviderSafeName.sanitized("🎉🎉")))
            #expect(isAcceptedByProviders(RTSProviderSafeName.sanitized("")))
            #expect(RTSProviderSafeName.sanitized("🎉🎉") != RTSProviderSafeName.sanitized(""))
        }

        @Test("Names with nothing decodable fall back to distinct hashes")
        func punctuationOnlyNamesStayDistinct() {
            let identifiers = ["", "  ", "...", "___"].map { RTSProviderSafeName.sanitized($0) }
            for identifier in identifiers {
                #expect(isAcceptedByProviders(identifier))
            }
            // Nothing survives escaping for any of these, so only a hash keeps them apart.
            #expect(Set(identifiers).count == identifiers.count)
        }

        @Test("Over-long names are truncated to the shortest provider limit")
        func overLongNamesTruncated() {
            let authored = String(repeating: "a", count: 200)
            let sanitized = RTSProviderSafeName.sanitized(authored)
            #expect(sanitized.count == RTSProviderSafeName.maxLength)
            #expect(isAcceptedByProviders(sanitized))
        }

        @Test("Truncation keeps names distinct even when they share a long prefix")
        func truncationStaysUnique() {
            let shared = String(repeating: "a", count: 80)
            let first = RTSProviderSafeName.sanitized(shared + "one")
            let second = RTSProviderSafeName.sanitized(shared + "two")
            #expect(first != second)
            #expect(isAcceptedByProviders(first))
            #expect(isAcceptedByProviders(second))
        }

        @Test("Truncation never splits an escape sequence")
        func truncationCutsOnEscapeBoundaries() {
            // 20 CJK characters: 120 characters of escapes, well past the limit.
            let authored = String(repeating: "写真検索記録", count: 4)
            let sanitized = RTSProviderSafeName.sanitized(authored)
            #expect(sanitized.count <= RTSProviderSafeName.maxLength)
            #expect(isAcceptedByProviders(sanitized))
            // Drop the `_h<hash>` uniqueness suffix, then every remaining escape must be whole —
            // a split escape would silently decode to a different character.
            let body = sanitized.components(separatedBy: "_h")[0]
            let decoded = decodeEscapes(body)
            #expect(authored.hasPrefix(decoded), "decoded prefix '\(decoded)' is not a prefix of the authored name")
            #expect(!decoded.isEmpty)
        }

        @Test("Every sanitized name satisfies the provider rule")
        func allSanitizedNamesAreAccepted() {
            let authored = [
                "Photo Summary Search",
                "photo.search:v2",
                "2fa check",
                "-tool",
                "写真検索",
                "🎉",
                "",
                "  ",
                "___",
                String(repeating: "Photo Summary ", count: 20),
                "Résumé Parser",
                "tool\nwith\tcontrol chars",
            ]
            for name in authored {
                let sanitized = RTSProviderSafeName.sanitized(name)
                #expect(isAcceptedByProviders(sanitized), "'\(name)' sanitized to illegal '\(sanitized)'")
            }
        }

        // MARK: - bridges

        @Test("Conduit tool bridge presents the sanitized name, node keeps the authored one")
        func conduitToolBridgeSanitizes() {
            let tool = StubTool(toolName: "Photo Summary Search")
            let agent = RTSAgent(llmProvider: .openAI(modelIDString: "gpt-4o"), name: "Root Agent")
            let invoker = RTSNodeInvoker(stampFactory: RTSStampFactory(), sessionID: UUID())
            let bridge = RTSConduitToolBridge(node: tool, nodeInvoker: invoker, createdBy: agent)

            #expect(bridge.name == "Photo_Summary_Search")
            // The trace identity is unchanged — this is what the visualizer and evaluation reports read.
            #expect(tool.toolName == "Photo Summary Search")
            #expect(tool.name() == "Photo Summary Search")
        }

        @Test("Agent-as-tool bridge sanitizes the wrapped agent's name")
        func conduitAgentToolBridgeSanitizes() {
            let wrapped = RTSAgent(llmProvider: .openAI(modelIDString: "gpt-4o"), name: "Photo Summary Agent")
            let agentTool = RTSAgentTool(
                agent: wrapped,
                description: "summarizes photos",
                parameters: RTSToolSchema(parameters: [])
            )
            let parent = RTSAgent(llmProvider: .openAI(modelIDString: "gpt-4o"), name: "Root Agent")
            let invoker = RTSNodeInvoker(stampFactory: RTSStampFactory(), sessionID: UUID())
            let bridge = RTSConduitAgentToolBridge(
                agentTool: agentTool,
                makeSession: { throw RTSError.encodingFailed() },
                onNewSession: { _ in },
                nodeInvoker: invoker,
                createdBy: parent
            )

            #expect(bridge.name == "Photo_Summary_Agent")
            #expect(wrapped.agentName == "Photo Summary Agent")
        }
    }
}
