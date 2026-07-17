//
//  RTSEvaluationIngest.swift
//  RailtracksSwift
//

import Foundation

/// Stage 1 of evaluation: turns a run trace (`RTSFlowGraph`) into `[RTSAgentDataPoint]`.
/// Per run it rebuilds the node/edge graph, then for each Agent node derives its LLM calls,
/// tool calls (ALL outgoing edge targets — no node-type filter), and I/O (first Completed
/// incoming edge). Mirrors Python's `extract_agent_data_points`; decoupled from evaluation.
public enum RTSEvaluationIngest {

    /// Decode and ingest a specific list of trace files. **Fail-soft:** a file that can't be read or
    /// decoded is skipped (emitting `.failed`) rather than aborting the whole ingest, so one corrupt
    /// trace can't sink a large batch. Emits `.ingesting` after each file — a skipped file still counts
    /// toward `filesCompleted` (so the bar reaches the total) but adds nothing to `runsProcessed`.
    ///
    /// TODO (follow-up — ingestion parallelism): files are decoded serially. Per-file decode is
    /// independent, so a `TaskGroup` could parallelize it. It won't overlap ingestion with evaluation
    /// (per-agent aggregation needs the complete set) — only speeds up the decode.
    public static func agentDataPoints(
        fromFiles urls: [URL],
        onEvent: (@Sendable (RTSEvaluationEvent) -> Void)? = nil
    ) -> [RTSAgentDataPoint] {
        let decoder = JSONDecoder()
        var dataPoints: [RTSAgentDataPoint] = []
        var runsProcessed = 0
        for (index, file) in urls.enumerated() {
            do {
                let graph = try decoder.decode(RTSFlowGraph.self, from: Data(contentsOf: file))
                let points = agentDataPoints(from: graph)
                dataPoints.append(contentsOf: points)
                runsProcessed += graph.runs.count
            } catch {
                log.error("🧪 could not decode trace \(file.lastPathComponent): \(error)")
                onEvent?(.ingestFailed(
                    file: file.lastPathComponent,
                    message: "could not decode: \(error)"
                ))
            }
            onEvent?(.ingesting(
                filesCompleted: index + 1,
                totalFiles: urls.count,
                runsProcessed: runsProcessed
            ))
        }
        return dataPoints
    }

    /// Decode and ingest every `.json` trace in a directory, optionally restricted to files
    /// whose name starts with `prefix` (dotfiles are always skipped). Per-file decode is fail-soft
    /// (see `agentDataPoints(fromFiles:onEvent:)`); only directory listing can throw.
    public static func agentDataPoints(
        inDirectory directory: URL,
        matchingPrefix prefix: String? = nil,
        onEvent: (@Sendable (RTSEvaluationEvent) -> Void)? = nil
    ) throws -> [RTSAgentDataPoint] {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                guard url.pathExtension == "json", !name.hasPrefix(".") else { return false }
                if let prefix { return name.hasPrefix(prefix) }
                return true
            }
        return agentDataPoints(fromFiles: files, onEvent: onEvent)
    }

    /// Ingest an already-decoded trace.
    public static func agentDataPoints(from graph: RTSFlowGraph) -> [RTSAgentDataPoint] {
        guard let sessionID = UUID(uuidString: graph.sessionID) else { return [] }
        return graph.runs.flatMap { dataPoints(from: $0, sessionID: sessionID) }
    }

    // MARK: - Per-run parsing

    /// Lookup key for an edge by its (source, target) endpoints; `source` is nil for the root edge.
    private struct EdgeKey: Hashable {
        let source: String?
        let target: String
    }

    private static func dataPoints(
        from run: RTSFlowRun,
        sessionID: UUID
    ) -> [RTSAgentDataPoint] {
        // Duplicate node identifiers can appear in a run; keep the last (matches Python's
        // dict-comprehension semantics).
        let nodesByID = Dictionary(
            run.nodes.map { ($0.identifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        var adjacency: [String: [String]] = [:]                 // source -> [target]
        var edgeByPair: [EdgeKey: RTSFlowGraphEdge] = [:]
        var sinkList: [String: [RTSFlowGraphEdge]] = [:]        // target -> [edge]
        for edge in run.edges {
            if let source = edge.source {
                adjacency[source, default: []].append(edge.target)
            }
            edgeByPair[EdgeKey(source: edge.source, target: edge.target)] = edge
            sinkList[edge.target, default: []].append(edge)
        }

        return run.nodes.compactMap { node -> RTSAgentDataPoint? in
            guard node.nodeType == .agent,
                  let id = UUID(uuidString: node.identifier)
            else { return nil }
            
            let llmCalls = (node.details.internals.llmDetails ?? []).enumerated().map { index, detail in
                RTSLLMCall(
                    modelName: detail.modelName,
                    modelProvider: detail.modelProvider,
                    input: detail.input.map { message in
                        RTSLLMIO(role: role(message.role), content: value(message.content))
                    },
                    output: RTSLLMIO(
                        role: role(detail.output.role),
                        content: value(detail.output.content)
                    ),
                    inputTokens: detail.inputTokens,
                    outputTokens: detail.outputTokens,
                    totalCost: detail.totalCost,
                    latency: detail.latency,
                    index: index
                )
            }

            // Tool calls = ALL outgoing edge targets (agents-as-tools included).
            var toolNames = Set<String>()
            var toolCalls: [RTSEvalToolCall] = []
            for targetID in adjacency[node.identifier] ?? [] {
                guard
                    let target = nodesByID[targetID],
                    let edge = edgeByPair[EdgeKey(source: node.identifier, target: targetID)],
                    let toolID = UUID(uuidString: targetID)
                else { continue }
                toolNames.insert(target.name)
                toolCalls.append(RTSEvalToolCall(
                    id: toolID,
                    name: target.name,
                    arguments: RTSToolArguments(
                        args: edge.details.inputArgs.map { RTSValue.string($0) },
                        kwargs: edge.details.inputKwargs.mapValues(value)
                    ),
                    output: value(edge.details.output),
                    runtime: target.details.internals.latency?.totalTime,
                    status: edge.details.status
                ))
            }

            // Agent I/O = first Completed incoming edge.
            var agentInput: RTSValue = .object([:])
            var agentOutput: RTSValue = .object([:])
            for edge in sinkList[node.identifier] ?? [] where edge.details.status == .completed {
                agentInput = .object([
                    "args": .array(edge.details.inputArgs.map { RTSValue.string($0) }),
                    "kwargs": .object(edge.details.inputKwargs.mapValues(value)),
                ])
                agentOutput = value(edge.details.output)
                break
            }

            return RTSAgentDataPoint(
                id: id,
                sessionID: sessionID,
                agentName: node.name,
                agentInput: agentInput,
                agentOutput: agentOutput,
                llmCalls: llmCalls,
                toolNames: toolNames,
                toolCalls: toolCalls
            )
        }
    }

    // MARK: - Conversions

    private static func value(_ content: RTSGeneratedContent) -> RTSValue {
        switch content.kind {
        case .null:                  return .null
        case .bool(let bool):        return .bool(bool)
        case .number(let number):    return .number(number)
        case .string(let string):    return .string(string)
        case .array(let elements):   return .array(elements.map(value))
        case .structure(let fields): return .object(fields.mapValues(value))
        }
    }

    private static func value(_ output: RTSEdgeOutput) -> RTSValue {
        switch output {
        case .structured(let content):
            return content.map(value) ?? .null
        case .agentStatus(let status):
            return .string(status)
        }
    }

    private static func role(_ rawValue: String) -> RTSEvalMessageRole {
        RTSEvalMessageRole(rawValue: rawValue) ?? .user
    }
}
