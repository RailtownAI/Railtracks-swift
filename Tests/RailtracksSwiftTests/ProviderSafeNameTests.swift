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

        @Test("Accented Latin loses the accent but keeps its shape")
        func accentedLatinSanitized() {
            #expect(RTSProviderSafeName.sanitized("Fotoübersicht") == "Foto_bersicht")
        }

        @Test("Non-Latin scripts fall back to a stable hash rather than a row of underscores")
        func nonLatinScriptsHashed() {
            let japanese = RTSProviderSafeName.sanitized("写真検索")
            #expect(japanese.hasPrefix("\(RTSProviderSafeName.fallback)_"))
            #expect(isAcceptedByProviders(japanese))
            // Same authored name always yields the same identifier — no per-process hash seed.
            #expect(RTSProviderSafeName.sanitized("写真検索") == japanese)
            // Two equal-length names of the same script must not collide, which a naive
            // character-for-character replacement would ("____" for both).
            #expect(RTSProviderSafeName.sanitized("写真要約") != japanese)
        }

        @Test("Decomposed and precomposed spellings yield the same identifier")
        func unicodeNormalizationIsStable() {
            // "Fotoübersicht" with a precomposed U+00FC vs. u + U+0308 combining diaeresis. Both are one
            // grapheme cluster, so sanitizing (which walks `Character`s) must not depend on normalization —
            // otherwise the same visible name could reach the provider under two different identifiers.
            let precomposed = "Foto\u{00FC}bersicht"
            let decomposed = "Fotou\u{0308}bersicht"
            #expect(precomposed.unicodeScalars.count != decomposed.unicodeScalars.count)
            #expect(RTSProviderSafeName.sanitized(precomposed) == RTSProviderSafeName.sanitized(decomposed))
            #expect(RTSProviderSafeName.sanitized(decomposed) == "Foto_bersicht")
        }

        @Test("A multi-scalar emoji collapses to one underscore, not one per scalar")
        func zeroWidthJoinerEmojiCollapses() {
            // Family emoji: five scalars joined by ZWJ, a single grapheme cluster.
            #expect(RTSProviderSafeName.sanitized("photo 👨‍👩‍👧 tool") == "photo___tool")
        }

        @Test("Emoji-only and empty names are still legal identifiers")
        func degenerateNamesAreLegal() {
            #expect(isAcceptedByProviders(RTSProviderSafeName.sanitized("🎉🎉")))
            #expect(isAcceptedByProviders(RTSProviderSafeName.sanitized("")))
            #expect(RTSProviderSafeName.sanitized("🎉🎉") != RTSProviderSafeName.sanitized(""))
        }

        @Test("Over-long names are truncated to the shortest provider limit")
        func overLongNamesTruncated() {
            let authored = String(repeating: "a", count: 200)
            let sanitized = RTSProviderSafeName.sanitized(authored)
            #expect(sanitized.count == RTSProviderSafeName.maxLength)
            #expect(isAcceptedByProviders(sanitized))
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
