//
//  RTSKnowledgeSearchTool.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-22.
//

import Foundation
import FoundationModels

/// A tool that lets an agent look something up in a knowledge source.
///
/// ```swift
/// let tool = RTSKnowledgeSearchTool(
///     toolName: "SearchDocs",
///     toolDescription: "Search the product documentation for passages answering a question.",
///     source: mySource
/// )
/// let agent = RTSAgent(name: "support", tools: [tool], llmProvider: …)
/// ```
///
/// ## Naming it is not decoration
///
/// ``toolName`` and ``toolDescription`` are construction parameters rather than constants, because
/// the description is the entire basis on which a model decides whether to call this. "Search the
/// product documentation" gets called for a product question; "search the knowledge base" gets
/// called for everything, or nothing. An app with two corpora builds two tools.
///
/// ## The model picks how many, within bounds this sets
///
/// `topK` is a required parameter — `RTSToolSchema.Parameter` cannot express an optional one, so
/// every declared parameter is required — and the tool clamps whatever arrives into
/// ``resultCountRange``. Results are truncated on the way *out* as well, since a custom
/// ``RTSKnowledgeSource`` is under no obligation to honour `topK` and an agent's context budget
/// should not depend on every conformer behaving.
///
/// ## Relevance is not filtered unless you ask
///
/// A vector store returns its top matches whether or not any of them are good — there is no
/// relevance floor in a nearest-neighbour search, so a store with enough entries answers every
/// question with something. ``minimumScore`` is what makes "nothing relevant" expressible, and it
/// defaults to `nil` because the right value depends on the embedder. See `docs/knowledge-tool.md`.
public struct RTSKnowledgeSearchTool: RTSToolNode {

    public let id = UUID()
    public let toolName: String
    public let toolDescription: String
    public var inputs: RTSInput = [:]
    public let callableRoutine: RTSClosure

    /// Bounds on how many passages one call may return.
    public let resultCountRange: ClosedRange<Int>
    /// Hits scoring below this are dropped. `nil` keeps everything the source returned.
    public let minimumScore: Double?

    /// - Parameters:
    ///   - toolName: What the model sees. Name the *corpus*, not the mechanism.
    ///   - toolDescription: When to call it, and what an empty result means. Worth a sentence
    ///     saying that nothing found means nothing relevant exists — an agent handed an empty array
    ///     with no guidance will often apologise and then guess anyway.
    ///   - source: Where lookups go.
    ///   - resultCountRange: Clamp applied to the model's requested count, and the bounds named in
    ///     the parameter description. Defaults to a deliberately small range: each passage is
    ///     chunk-sized, so five of them is already a meaningful slice of a context window.
    ///   - minimumScore: Drop hits below this score. `nil` — the default — keeps everything, which
    ///     matches what a store does on its own. Calibrate against a real corpus by asking
    ///     questions you know are unanswerable and watching what comes back.
    public init(
        toolName: String,
        toolDescription: String,
        source: any RTSKnowledgeSource,
        resultCountRange: ClosedRange<Int> = 1...5,
        minimumScore: Double? = nil
    ) {
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.resultCountRange = resultCountRange
        self.minimumScore = minimumScore
        self.callableRoutine = RTSClosure { inputs in
            try await RTSKnowledgeSearchTool.search(
                inputs: inputs,
                source: source,
                resultCountRange: resultCountRange,
                minimumScore: minimumScore
            )
        }
    }

    public var parameterSchema: RTSToolSchema {
        RTSToolSchema(
            parameters: [
                .init(
                    name: RTSKnowledgeSearchTool.queryKey,
                    description: "What to look up, phrased as the question or topic to find passages about.",
                    type: .string
                ),
                .init(
                    name: RTSKnowledgeSearchTool.topKKey,
                    description: """
                    How many passages to return, from \(resultCountRange.lowerBound) to \
                    \(resultCountRange.upperBound). Ask for more only when one passage is unlikely \
                    to hold the whole answer.
                    """,
                    type: .number
                ),
            ]
        )
    }

    // MARK: - Lookup

    /// `static` so the closure built in `init` captures only what it needs, rather than a
    /// half-initialised `self`.
    private static func search(
        inputs: RTSInput,
        source: any RTSKnowledgeSource,
        resultCountRange: ClosedRange<Int>,
        minimumScore: Double?
    ) async throws -> RTSOutput {
        guard case .string(let text) = inputs[RTSKnowledgeSearchTool.queryKey] else {
            throw RTSError.missingInput(RTSKnowledgeSearchTool.queryKey)
        }
        let requested: Int
        if case .number(let raw) = inputs[RTSKnowledgeSearchTool.topKKey] {
            requested = Int(raw)
        } else {
            // Defensive only — the parameter is required, so a well-formed call always carries it.
            requested = resultCountRange.lowerBound
        }
        let topK = min(max(requested, resultCountRange.lowerBound), resultCountRange.upperBound)

        let hits = try await source.retrieve(RTSKnowledgeQuery(text: text, topK: topK))
        // Filtered *then* truncated, so a source that over-returns cannot push relevant hits out
        // of the window with irrelevant ones it was never asked for.
        let relevant = minimumScore.map { floor in hits.filter { $0.score >= floor } } ?? hits
        let results = relevant.prefix(topK).map { RTSKnowledgeSearchTool.encode($0) }

        return [RTSKnowledgeSearchTool.resultsKey: .array(results)]
    }

    private static func encode(_ hit: RTSKnowledgeHit) -> RTSValue {
        var fields: [String: RTSValue] = [
            "content": .string(hit.content),
            "score": .number(hit.score),
        ]
        // Omitted rather than sent as null: a model reading `"source": null` tends to mention the
        // absence, which is noise when most corpora have a source for everything.
        if let source = hit.source {
            fields["source"] = .string(source)
        }
        if !hit.metadata.isEmpty {
            fields["metadata"] = .object(hit.metadata)
        }
        return .object(fields)
    }

    // MARK: - Keys

    static let queryKey = "query"
    static let topKKey = "topK"
    static let resultsKey = "results"
}

// MARK: - On-device (FoundationModels)

/// Makes the same tool callable by Apple's on-device model.
///
/// The Apple path hands `LanguageModelSession` only agent tools, orchestrator tools and
/// ``RTSAppleAIToolNode``s; any other ``RTSToolNode`` is dropped with a warning. Without this, an
/// `RTSAgent(llmProvider: .appleAI)` given this tool would silently have no search at all.
///
/// **The availability sits on the conformance, not on the type.** ``RTSAppleAIToolNode`` requires
/// macOS 26 / iOS 26 because it builds on FoundationModels' `Tool`; marking the type would lift the
/// tool above the package's macOS 15 / iOS 18 floor. Gated here, it stays one type everywhere, and
/// is an ``RTSAppleAIToolNode`` only where FoundationModels exists — which is exactly where the
/// Apple path's dynamic cast looks for it.
///
/// Only `Arguments` and `Output` are declared. The protocol's defaults bridge `call(arguments:)` to
/// the existing ``callableRoutine`` and route it through `RTSNodeInvoker`, so an on-device call is
/// traced like a cloud one. The explicit ``parameterSchema`` above still takes precedence, keeping
/// the dynamic result-count text that a `@Guide` literal cannot express.
@available(macOS 26, iOS 26, *)
extension RTSKnowledgeSearchTool: RTSAppleAIToolNode {

    /// Property names must equal ``queryKey`` and ``topKKey``: the default `call(arguments:)`
    /// round-trips these through JSON into the `RTSInput` that ``callableRoutine`` reads.
    @Generable
    public struct Arguments: Encodable {
        @Guide(
            description: """
            What to look up, phrased as the question or topic to find passages about.
            """
        )
        public var query: String
        @Guide(
            description: """
            How many passages to return. Ask for more only when one passage is unlikely to hold \
            the whole answer.
            """
        )
        public var topK: Int
    }

    public typealias Output = String
}
