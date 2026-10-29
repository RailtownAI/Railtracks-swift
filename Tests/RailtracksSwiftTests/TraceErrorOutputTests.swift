//
//  TraceErrorOutputTests.swift
//  RailtracksSwiftTests
//

import Combine
import Foundation
import Testing
@testable import RailtracksSwift

/// Captures the trace file a flow writes. `run` returns only after the trace is written, so the URL
/// is there by the time a test asks for it.
private final class TraceURLWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var written: URL?
    private var cancellable: AnyCancellable?

    init(_ publisher: AnyPublisher<Result<URL, Error>, Never>) {
        cancellable = publisher.sink { [weak self] result in
            guard let self, case .success(let url) = result else {
                return
            }
            self.lock.lock()
            self.written = url
            self.lock.unlock()
        }
    }

    func url() throws -> URL {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try #require(written, "the trace should be written before run returns")
    }
}

/// Minimal orchestrator whose body is supplied as a closure, so a real `RTSFlow` runs with no LLM.
private struct FailingOrchestrator: RTSOrchestratorNode {
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

/// The finished edges of a trace's first run, keyed by target node name, as raw JSON: what the v1
/// visualizer reads.
private func rawEdgeOutputs(of data: Data) throws -> [String: Any] {
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let runs = try #require(root["runs"] as? [[String: Any]])
    let run = try #require(runs.first)
    let nodes = try #require(run["nodes"] as? [[String: Any]])
    let edges = try #require(run["edges"] as? [[String: Any]])
    var namesByID: [String: String] = [:]
    for node in nodes {
        if let identifier = node["identifier"] as? String, let name = node["name"] as? String {
            namesByID[identifier] = name
        }
    }
    var outputs: [String: Any] = [:]
    for edge in edges {
        guard let target = edge["target"] as? String,
              let name = namesByID[target],
              let details = edge["details"] as? [String: Any] else {
            continue
        }
        outputs[name] = details["output"] ?? NSNull()
    }
    return outputs
}

extension RailtracksSwiftTestSuite {
    @Suite("Trace error output", .serialized)
    struct TraceErrorOutputTests {

        /// A failed edge writes Python's `Failure.encode` object, `{type, message, traceback}`,
        /// which is what the v1 visualizer needs to show its error panel. An `RTSError` carries its
        /// call site as the traceback; both the failing node and the root it propagated to get it.
        @Test("a failed edge writes {type, message, traceback}")
        func failedEdgeWritesTheFailureObject() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let child = FailingOrchestrator(nodeName: "Divide") { _, _ in
                throw RTSError.invalidInvocation("Division by zero")
            }
            let root = FailingOrchestrator(nodeName: "Root") { _, context in
                try await context.call(child, input: [:])
            }
            let flow = RTSFlow(title: "TraceErrorOutput")
            let traceURL = TraceURLWaiter(flow.outputFileURLPublisher)

            _ = try? await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let url = try traceURL.url()
            let outputs = try rawEdgeOutputs(of: Data(contentsOf: url))
            for name in ["Divide", "Root"] {
                let output = try #require(outputs[name] as? [String: Any], "\(name)'s output should be an object")
                #expect(output["type"] as? String == "RTSError")
                #expect(output["message"] as? String == "invalidInvocation(\"Division by zero\")")
                let traceback = try #require(output["traceback"] as? String)
                #expect(traceback.hasPrefix("thrown at "), "unexpected traceback \(traceback)")
            }
        }

        /// An error from outside the library has no call site, so its traceback is null; `type` and
        /// `message` are still enough for the v1 visualizer.
        @Test("a non-RTSError failure has a null traceback")
        func foreignErrorHasNullTraceback() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let root = FailingOrchestrator(nodeName: "Fetch") { _, _ in
                throw URLError(.badServerResponse)
            }
            let flow = RTSFlow(title: "TraceForeignError")
            let traceURL = TraceURLWaiter(flow.outputFileURLPublisher)

            _ = try? await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let url = try traceURL.url()
            let outputs = try rawEdgeOutputs(of: Data(contentsOf: url))
            let output = try #require(outputs["Fetch"] as? [String: Any])
            // Foundation errors arrive bridged, so the type reads `NSError`, the same name the
            // events' `exception_name` reports for them.
            let type = try #require(output["type"] as? String)
            #expect(!type.isEmpty)
            let message = try #require(output["message"] as? String)
            #expect(message.contains("NSURLErrorDomain"))
            #expect(output["traceback"] is NSNull)
        }

        /// An agent edge and a tool edge both write the object, the trace decodes back, and
        /// evaluation ingest reads a failed tool call's output as that object.
        @Test("agent and tool edges write the object, and ingest reads it")
        func agentAndToolEdgesAndIngest() async throws {
            let failure = RTSEdgeFailure(RTSError.invalidInvocation("Division by zero"))
            let graph = await agentWithFailedTool(failure: failure)

            let data = try JSONEncoder().encode(graph)
            let outputs = try rawEdgeOutputs(of: data)
            for name in ["Agent", "Division"] {
                let output = try #require(outputs[name] as? [String: Any], "\(name)'s output should be an object")
                #expect(output["type"] as? String == "RTSError")
                #expect(output["message"] as? String == "invalidInvocation(\"Division by zero\")")
            }

            let decoded = try JSONDecoder().decode(RTSFlowGraph.self, from: data)
            let dataPoint = try #require(RTSEvaluationIngest.agentDataPoints(from: decoded).first)
            let toolCall = try #require(dataPoint.toolCalls.first)
            #expect(toolCall.status == .failed)
            guard case .object(let fields) = toolCall.output else {
                Issue.record("expected the failed tool's output as an object, got \(toolCall.output)")
                return
            }
            #expect(fields["type"] == .string("RTSError"))
            #expect(fields["message"] == .string("invalidInvocation(\"Division by zero\")"))
        }

        /// Builds the trace of an agent whose one tool call failed, with that failure propagated to
        /// the agent: create and finish events for both nodes and both edges.
        private func agentWithFailedTool(failure: RTSEdgeFailure) async -> RTSFlowGraph {
            let agentID = UUID()
            let toolID = UUID()
            let agentRunID = UUID()
            let toolRunID = UUID()
            let rootEdgeID = UUID()
            let toolEdgeID = UUID()
            let nodeEvents = [
                RTSNodeEvent(
                    nodeID: agentID,
                    name: "Agent",
                    nodeType: .agent,
                    stamp: RTSStamp(stepIndex: 0, event: .startCreate("Agent"))
                ),
                RTSNodeEvent(
                    nodeID: toolID,
                    parentNodeID: agentID,
                    name: "Division",
                    nodeType: .tool,
                    stamp: RTSStamp(stepIndex: 1, event: .create("Agent", "Division"))
                ),
                RTSNodeEvent(
                    nodeID: toolID,
                    parentNodeID: agentID,
                    name: "Division",
                    nodeType: .tool,
                    stamp: RTSStamp(stepIndex: 2, event: .finishExecution("Division")),
                    error: failure.message,
                    runID: toolRunID
                ),
                RTSNodeEvent(
                    nodeID: agentID,
                    name: "Agent",
                    nodeType: .agent,
                    stamp: RTSStamp(stepIndex: 3, event: .finishExecution("Agent")),
                    error: failure.message,
                    runID: agentRunID
                ),
            ]
            let edgeEvents = [
                edge(rootEdgeID, agentRunID, step: 0, .startCreate("Agent"), .agent, nil, agentID, "Agent"),
                edge(toolEdgeID, toolRunID, step: 1, .create("Agent", "Division"), .tool, agentID, toolID, "Division"),
                edge(toolEdgeID, toolRunID, step: 2, .finishExecution("Division"), .tool, agentID, toolID, "Division", failure),
                edge(rootEdgeID, agentRunID, step: 3, .finishExecution("Agent"), .agent, nil, agentID, "Agent", failure),
            ]
            return await RTSFlowGraph.make(
                flowName: "AgentWithFailedTool",
                sessionID: UUID(),
                nodeEvents: nodeEvents,
                edgeEvents: edgeEvents,
                rootNodeID: agentID,
                startTime: 0,
                endTime: 1
            )
        }

        /// One edge event, failed when `failure` is given.
        private func edge(
            _ id: UUID,
            _ runID: UUID,
            step: Int,
            _ event: RTSStamp.Event,
            _ nodeType: RTSFlowNodeType,
            _ source: UUID?,
            _ target: UUID,
            _ targetName: String,
            _ failure: RTSEdgeFailure? = nil
        ) -> RTSEdgeEvent {
            RTSEdgeEvent(
                id: id,
                runID: runID,
                stamp: RTSStamp(stepIndex: step, event: event),
                nodeType: nodeType,
                sourceNodeID: source,
                targetNodeID: target,
                sourceName: source == nil ? nil : "Agent",
                targetName: targetName,
                input: ["prompt": .string("divide")],
                output: nil,
                error: failure?.message,
                failure: failure
            )
        }
    }
}
