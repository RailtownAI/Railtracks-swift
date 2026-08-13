//
//  DuplicateNodeIdTests.swift
//  RailtracksSwiftTests
//
//  Verifies per-invocation node ids: a node invoked N times produces N distinct graph node ids,
//  each edge correctly linked to its parent *invocation* — matching Python. Exercises the full
//  pipeline (RTSNodeInvoker → collector → parser → JSON) using orchestrator stubs (no LLM).
//

import Testing
import Foundation
import Combine
@testable import RailtracksSwift

/// Minimal orchestrator whose body is supplied as a closure (mirrors FunctionNodeTests).
private struct StubOrchestrator: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName: String
    let body: @Sendable (RTSInput, RTSRunContext) async throws -> RTSOutput

    func name() -> String {
        nodeName
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        try await body(input, context)
    }
}

// Serialized: runs a full `RTSFlow`, which touches process-global state (`flowGraphOutputDirectory`).
extension RailtracksSwiftTestSuite {
    @Suite("Duplicate node ids", .serialized)
    struct DuplicateNodeIdTests {

        /// Runs `root` as a flow and returns the decoded run. Reads the exact file the flow wrote via its
        /// `outputFileURLPublisher` rather than scanning the output directory — `flowGraphOutputDirectory`
        /// is a process-global that other suites' flows mutate concurrently, so a directory scan is racy.
        private func runAndLoadRun(title: String, root: some RTSOrchestratorNode) async throws -> RTSFlowRun {
            RailtracksSwift.flowGraphOutputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: title)
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let url = try await writtenTraceURL(flow)
            let graph = try JSONDecoder().decode(RTSFlowGraph.self, from: Data(contentsOf: url))
            return try #require(graph.runs.first, "trace should contain a run")
        }

        /// The exact file this flow wrote, via its `outputFileURLPublisher`. The backing subject is a
        /// `CurrentValueSubject`, so it replays the post-run value to a late subscriber — the first
        /// element is this run's result.
        private func writtenTraceURL(_ flow: RTSFlow) async throws -> URL {
            for await result in flow.outputFileURLPublisher.values {
                switch result {
                case .success(let url):
                    return url
                case .failure(let error):
                    throw error
                }
            }
            struct NoTraceURL: Error {}
            throw NoTraceURL()
        }

        /// A child invoked twice by one parent yields two distinct node ids, each edge sourced at the
        /// single parent node. Under the old per-instance id, both invocations collapsed to one id.
        @Test("a node invoked twice gets two distinct ids, both linked to the parent")
        func repeatedChildGetsDistinctIds() async throws {
            let child = StubOrchestrator(nodeName: "Child") { _, _ in
                ["result": .string("ok")]
            }
            let parent = StubOrchestrator(nodeName: "Parent") { _, context in
                _ = try await context.call(child, input: [:])
                _ = try await context.call(child, input: [:])
                return ["result": .string("done")]
            }

            let run = try await runAndLoadRun(title: "DupIdRepeated", root: parent)

            // Two distinct Child nodes.
            let childNodes = run.nodes.filter { $0.name == "Child" }
            #expect(childNodes.count == 2)
            let childIDs = Set(childNodes.map { $0.identifier })
            #expect(childIDs.count == 2)

            // Exactly one Parent node.
            let parentNodes = run.nodes.filter { $0.name == "Parent" }
            #expect(parentNodes.count == 1)
            let parentID = try #require(parentNodes.first?.identifier)

            // Two edges into the two Child invocations, both sourced at the single Parent node.
            let childEdges = run.edges.filter { childIDs.contains($0.target) }
            #expect(childEdges.count == 2)
            #expect(Set(childEdges.map { $0.target }).count == 2)          // distinct targets
            #expect(childEdges.allSatisfy { $0.source == parentID })       // both from the parent

            // The parent's own edge is the root edge (no source).
            let rootEdges = run.edges.filter { $0.source == nil }
            #expect(rootEdges.count == 1)
            #expect(rootEdges.first?.target == parentID)
        }

        /// Parent-invocation id propagates through a middle layer: when a middle node is invoked twice
        /// and each invocation calls a leaf, each leaf must attach to its *own* middle invocation — not
        /// a shared one. This is the case the old per-instance id could not represent.
        @Test("repeated middle node links each leaf to its own invocation")
        func nestedInvocationLinkage() async throws {
            let leaf = StubOrchestrator(nodeName: "Leaf") { _, _ in
                ["result": .string("leaf")]
            }
            let middle = StubOrchestrator(nodeName: "Middle") { _, context in
                _ = try await context.call(leaf, input: [:])
                return ["result": .string("mid")]
            }
            let parent = StubOrchestrator(nodeName: "Parent") { _, context in
                _ = try await context.call(middle, input: [:])
                _ = try await context.call(middle, input: [:])
                return ["result": .string("done")]
            }

            let run = try await runAndLoadRun(title: "DupIdNested", root: parent)

            let middleNodes = run.nodes.filter { $0.name == "Middle" }
            let leafNodes = run.nodes.filter { $0.name == "Leaf" }
            #expect(middleNodes.count == 2)
            #expect(leafNodes.count == 2)

            let middleIDs = Set(middleNodes.map { $0.identifier })
            #expect(middleIDs.count == 2)

            // Each leaf edge sources at a *distinct* middle invocation, and each is a real middle id.
            let leafIDs = Set(leafNodes.map { $0.identifier })
            let leafEdges = run.edges.filter { leafIDs.contains($0.target) }
            #expect(leafEdges.count == 2)
            let leafSources = Set(leafEdges.compactMap { $0.source })
            #expect(leafSources.count == 2)                    // two different middle invocations
            #expect(leafSources.isSubset(of: middleIDs))       // each is a genuine middle invocation id
        }
    }
}
