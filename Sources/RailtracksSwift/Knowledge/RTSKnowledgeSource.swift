//
//  RTSKnowledgeSource.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-22.
//

import Foundation

// MARK: - RTSKnowledgeQuery

/// One lookup: what to search for, and how many passages to bring back.
///
/// **A struct rather than loose parameters, to leave room for filtering.** Nothing filters today —
/// scoping belongs in the conformer, where a tenant-isolating source binds its scope at
/// construction so the agent cannot widen its own access. But nothing can intercept a tool call
/// today either: there is no middleware layer, and guardrails run in `RTSNodeInvoker.invokeAgent`,
/// never `invokeTool`. When a tool-boundary hook arrives, a filter injected there needs somewhere
/// to land — and a new field here is non-breaking for callers *and* conformers, where a new
/// parameter on ``RTSKnowledgeSource/retrieve(_:)`` would break every conformer at once.
public struct RTSKnowledgeQuery: Sendable {

    /// What the agent asked, verbatim.
    public let text: String
    /// How many passages to return, already clamped by the tool. A conformer may return fewer.
    public let topK: Int

    public init(
        text: String,
        topK: Int
    ) {
        self.text = text
        self.topK = topK
    }
}

// MARK: - RTSKnowledgeHit

/// One passage a lookup found.
///
/// ``source`` and ``metadata`` exist so an agent asked *"where did that come from?"* can answer.
/// Without them a retrieved passage is an assertion with no provenance, which is the thing users
/// distrust most about retrieval-backed answers.
public struct RTSKnowledgeHit: Sendable {

    /// The passage itself — what goes into the model's context.
    public let content: String
    /// Where it came from: a file path, a URL, a record id. `nil` when the source cannot say.
    public let source: String?
    /// Higher is more similar. Comparable only among hits from one query, and only when every hit
    /// came from the same embedding model.
    public let score: Double
    /// Anything else worth citing or filtering on.
    ///
    /// ``RTSValue`` rather than `[String: String]`: it is this module's own JSON-shaped type, with
    /// the same cases as a retrieval module's metadata enum, so a conformer maps losslessly — and
    /// the tool's output is built from `RTSValue` anyway, so nothing is converted twice.
    public let metadata: [String: RTSValue]

    public init(
        content: String,
        source: String? = nil,
        score: Double = 0,
        metadata: [String: RTSValue] = [:]
    ) {
        self.content = content
        self.source = source
        self.score = score
        self.metadata = metadata
    }
}

// MARK: - RTSKnowledgeSource

/// Anything that can answer a text query with passages.
///
/// The seam that keeps ``RTSKnowledgeSearchTool`` free of any retrieval dependency. A vector store
/// behind `RailtracksSwiftRAG` conforms, and so does a remote vector database, an in-house index,
/// or a hardcoded FAQ — this module never learns which.
///
/// The inversion is deliberate. A tool here that imported a retrieval module would make every
/// agent-only consumer compile it, and would spend the independence that makes that module cheap to
/// extract. See `docs/knowledge-tool.md`.
public protocol RTSKnowledgeSource: Sendable {
    func retrieve(_ query: RTSKnowledgeQuery) async throws -> [RTSKnowledgeHit]
}

// MARK: - Closure conformer

/// Closure-backed knowledge source, for wiring an existing retrieval stack up inline.
///
/// This is what removes the need for a bridge target between this module and a retrieval one. The
/// alternative — `extension SomeRuntime: RTSKnowledgeSource` — is a **retroactive** conformance
/// wherever it is written, since no module owns both the type and this protocol, so it would carry
/// `@retroactive` and risk colliding with anyone else who wrote the same one. Constructing a value
/// extends nothing.
///
/// ```swift
/// RTSClosureKnowledgeSource { query in
///     try await runtime.retrieve(query.text, topK: query.topK).entries.map { hit in
///         var source: String?
///         if case .string(let path)? = hit.entry.metadata[RTSRAGChunk.MetadataKey.sourcePath] {
///             source = path
///         }
///         return RTSKnowledgeHit(
///             content: hit.entry.content,
///             source: source,
///             score: Double(hit.score)
///         )
///     }
/// }
/// ```
///
/// Mirrors ``RTSClosureInputGuardrail``, which solves the same problem for guardrails.
public struct RTSClosureKnowledgeSource: RTSKnowledgeSource {

    private let closure: @Sendable (RTSKnowledgeQuery) async throws -> [RTSKnowledgeHit]

    public init(_ closure: @escaping @Sendable (RTSKnowledgeQuery) async throws -> [RTSKnowledgeHit]) {
        self.closure = closure
    }

    public func retrieve(_ query: RTSKnowledgeQuery) async throws -> [RTSKnowledgeHit] {
        try await closure(query)
    }
}
