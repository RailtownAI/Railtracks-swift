//
//  RTSFlowGraph+Parser.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-12.
//

import Foundation

extension RTSFlowGraph {
    static func make(
        flowName: String,
        sessionID: UUID,
        nodeEvents: [RTSNodeEvent],
        edgeEvents: [RTSEdgeEvent],
        rootNodeID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async -> RTSFlowGraph {
        let createsByNodeID: [UUID: RTSNodeEvent] = nodeEvents
            .filter { $0.runID == nil }
            .reduce(into: [:]) { $0[$1.id] = $1 }

        let finishEvents = nodeEvents.filter { $0.runID != nil }

        let allStamps = nodeEvents
            .map { $0.stamp }
            .sorted { $0.stepIndex < $1.stepIndex }

        let steps = allStamps.map {
            RTSFlowGraphStamp(step: $0.stepIndex, time: $0.timestamp.timeIntervalSince1970, identifier: $0.event.identifier)
        }

        var nodes: [RTSFlowGraphNode] = []
        for finish in finishEvents {
            nodes.append(await makeNode(finish: finish, create: createsByNodeID[finish.id]))
        }

        let rootFinish = finishEvents.first { $0.id == rootNodeID }

        let edges = makeEdges(from: edgeEvents)

        let run = RTSFlowRun(
            name: rootFinish?.name ?? flowName,
            runID: rootFinish?.runID?.uuidString ?? "N/A",
            nodes: nodes,
            status: .completed, // TODO: 5893 - reflect actual status once error propagation is implemented
            edges: edges,
            steps: steps,
            startTime: startTime,
            endTime: endTime
        )

        return RTSFlowGraph(
            flowName: flowName,
            flowID: RailtracksSwift.equalityHash(flowName),
            sessionID: sessionID.uuidString,
            sessionName: nil,
            startTime: startTime,
            endTime: endTime,
            runs: [run]
        )
    }

    // MARK: - Node

    private static func makeNode(finish: RTSNodeEvent, create: RTSNodeEvent?) async -> RTSFlowGraphNode {
        let nodeType = (create ?? finish).nodeType
        let latency = create.map {
            RTSFlowGraphLatency(totalTime: finish.stamp.timestamp.timeIntervalSince($0.stamp.timestamp))
        }
        let parent: RTSFlowGraphNodeCreation? = create.map {
            RTSFlowGraphNodeCreation(
                identifier: $0.id.uuidString,
                nodeType: nodeType,
                name: $0.name,
                stamp: $0.stamp.toFlowGraphStamp(),
                details: RTSFlowGraphNodeDetails(internals: RTSFlowGraphNodeInternals(llmDetails: nil, latency: nil))
            )
        }
        return RTSFlowGraphNode(
            identifier: finish.id.uuidString,
            nodeType: nodeType,
            name: finish.name,
            stamp: finish.stamp.toFlowGraphStamp(),
            details: RTSFlowGraphNodeDetails(
                internals: RTSFlowGraphNodeInternals(
                    llmDetails: finish.messages.isEmpty ? nil : await makeLLMDetails(from: finish.messages),
                    latency: latency
                )
            ),
            parent: parent
        )
    }

    // MARK: - Edge

    private static func makeEdges(from edgeEvents: [RTSEdgeEvent]) -> [RTSFlowGraphEdge] {
        let createsByEdgeID: [UUID: RTSEdgeEvent] = edgeEvents
            .filter { if case .finishExecution = $0.stamp.event { false } else { true } }
            .reduce(into: [:]) { $0[$1.id] = $1 }

        let finishEvents = edgeEvents.filter {
            if case .finishExecution = $0.stamp.event { true } else { false }
        }

        return finishEvents.map { finish in
            makeEdge(finish: finish, create: createsByEdgeID[finish.id])
        }
    }

    private static func makeEdge(finish: RTSEdgeEvent, create: RTSEdgeEvent?) -> RTSFlowGraphEdge {
        let parent: RTSFlowGraphEdgeCreation? = create.map {
            RTSFlowGraphEdgeCreation(
                source: $0.sourceNodeID?.uuidString,
                target: $0.targetNodeID.uuidString,
                identifier: $0.id.uuidString,
                stamp: $0.stamp.toFlowGraphStamp(),
                details: makeEdgeDetails(from: $0, status: .open)
            )
        }
        return RTSFlowGraphEdge(
            source: finish.sourceNodeID?.uuidString,
            target: finish.targetNodeID.uuidString,
            identifier: finish.id.uuidString,
            stamp: finish.stamp.toFlowGraphStamp(),
            details: makeEdgeDetails(from: finish, status: finish.error == nil ? .completed : .failed),
            parent: parent
        )
    }

    private static func makeEdgeDetails(from event: RTSEdgeEvent, status: RTSFlowStatus) -> RTSFlowGraphEdgeDetails {
        let inputKwargs: [String: RTSGeneratedContent] = (event.input ?? [:]).mapValues { $0.toGeneratedContent() }
        let output: RTSEdgeOutput = switch event.nodeType {
        case .tool:
            .structured(event.output.map { RTSGeneratedContent(kind: .structure($0.mapValues { $0.toGeneratedContent() })) })
        case .agent:
            .agentStatus(event.error == nil ? "Success" : "Failed")
        }
        return RTSFlowGraphEdgeDetails(
            inputArgs: [],
            inputKwargs: inputKwargs,
            status: status,
            output: output
        )
    }

    // MARK: - LLM Details

    // Each assistant message marks the end of one LLM call round.
    // Input for each round is all messages accumulated up to that point.
    private static func makeLLMDetails(from messages: [RTSMessage]) async -> [RTSFlowGraphLLMDetail] {
        var details: [RTSFlowGraphLLMDetail] = []
        for (index, message) in messages.enumerated() {
            guard message.role == .assistant else { continue }
            let inputTokens = message.metadata?.inputTokenCount ?? 0
            let outputTokens = message.metadata?.tokenCount ?? 0
            let modelName = message.metadata?.model ?? "unknown" // TODO: model not always populated on assistant messages
            let usage = RTSTokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)
            let cost = try? await RTSCostCalculator.shared.calculateCost(model: modelName, usage: usage)
            details.append(RTSFlowGraphLLMDetail(
                modelName: modelName,
                modelProvider: message.metadata?.providerName ?? "unknown",
                input: Array(messages[0..<index]).map { $0.toFlowGraphMessage() },
                output: message.toFlowGraphMessage(),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalCost: cost?.totalCost,
                systemFingerprint: message.metadata?.providerExtra?["system_fingerprint"],
                latency: message.metadata?.generationTime ?? 0
            ))
        }
        return details
    }
}

// MARK: - Helpers

private extension RTSStamp {
    func toFlowGraphStamp() -> RTSFlowGraphStamp {
        RTSFlowGraphStamp(
            step: stepIndex,
            time: timestamp.timeIntervalSince1970,
            identifier: event.identifier
        )
    }
}

private extension RTSValue {
    func toGeneratedContent() -> RTSGeneratedContent {
        switch self {
        case .null:               return RTSGeneratedContent(kind: .null)
        case .bool(let v):        return RTSGeneratedContent(kind: .bool(v))
        case .number(let v):      return RTSGeneratedContent(kind: .number(v))
        case .string(let v):      return RTSGeneratedContent(kind: .string(v))
        case .array(let elements): return RTSGeneratedContent(kind: .array(elements.map { $0.toGeneratedContent() }))
        case .object(let props):  return RTSGeneratedContent(kind: .structure(props.mapValues { $0.toGeneratedContent() }))
        }
    }
}

private extension RTSMessage {
    func toFlowGraphMessage() -> RTSFlowGraphMessage {
        let content: RTSGeneratedContent
        if role == .tool, let toolCallID = metadata?.custom?["tool_call_id"] {
            content = RTSGeneratedContent(kind: .structure([
                "identifier": RTSGeneratedContent(kind: .string(toolCallID)),
                "name": RTSGeneratedContent(kind: .string(metadata?.custom?["tool_name"] ?? "")),
                "result": RTSGeneratedContent(kind: .string(self.content.textValue))
            ]))
        } else if let toolCalls = metadata?.toolCalls, !toolCalls.isEmpty {
            content = RTSGeneratedContent(kind: .array(toolCalls.map { call in
                RTSGeneratedContent(kind: .structure([
                    "identifier": RTSGeneratedContent(kind: .string(call.id)),
                    "name": RTSGeneratedContent(kind: .string(call.toolName)),
                    "arguments": call.arguments
                ]))
            }))
        } else {
            switch self.content {
            case .text(let string):
                content = RTSGeneratedContent(kind: .string(string))
            case .parts:
                // TODO: map ContentPart array (images, audio) to structured RTSGeneratedContent
                content = RTSGeneratedContent(kind: .string(self.content.textValue))
            }
        }
        return RTSFlowGraphMessage(role: role.rawValue, content: content)
    }
}
