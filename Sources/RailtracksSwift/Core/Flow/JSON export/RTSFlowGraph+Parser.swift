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
    ) -> RTSFlowGraph {
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

        let nodes = finishEvents.map { finish in
            makeNode(finish: finish, create: createsByNodeID[finish.id])
        }

        let rootFinish = finishEvents.first { $0.id == rootNodeID }
        let startTime = startTime
        let endTime = endTime 

        let edges = makeEdges(from: edgeEvents)

        let run = RTSFlowRun(
            name: rootFinish?.name ?? flowName,
            runID: rootFinish?.runID?.uuidString ?? "N/A", // TODO: runID shouldn't be empty
            nodes: nodes,
            status: .completed, // TODO: reflect actual status once error propagation is implemented
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

    private static func makeNode(finish: RTSNodeEvent, create: RTSNodeEvent?) -> RTSFlowGraphNode {
        let nodeType = inferNodeType(from: create ?? finish)
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
                    llmDetails: finish.messages.isEmpty ? nil : makeLLMDetails(from: finish.messages),
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
        let output: RTSGeneratedContent? = event.output.map { output in
            RTSGeneratedContent(kind: .structure(output.mapValues { $0.toGeneratedContent() }))
        }
        return RTSFlowGraphEdgeDetails(
            inputArgs: [],
            inputKwargs: inputKwargs,
            status: status,
            output: output
        )
    }

    // Heuristic: .startCreate = root agent, .create = tool (only tools use createdBy in current design).
    // TODO: add explicit nodeType to RTSNodeEvent when sub-agents are introduced
    private static func inferNodeType(from event: RTSNodeEvent) -> RTSFlowNodeType {
        switch event.stamp.event {
        case .startCreate:     return .agent
        case .create:          return .tool
        case .finishExecution: return .agent
        }
    }

    // MARK: - LLM Details

    // Each assistant message marks the end of one LLM call round.
    // Input for each round is all messages accumulated up to that point.
    private static func makeLLMDetails(from messages: [RTSMessage]) -> [RTSFlowGraphLLMDetail] {
        messages.enumerated().compactMap { index, message in
            guard message.role == .assistant else { return nil }
            return RTSFlowGraphLLMDetail(
                modelName: message.metadata?.model ?? "unknown", // TODO: model not always populated on assistant messages
                modelProvider: "unknown",                         // TODO: model provider not tracked in RTSMessageMetadata
                input: Array(messages[0..<index]).map { $0.toFlowGraphMessage() },
                output: message.toFlowGraphMessage(),
                inputTokens: 0,                                   // TODO: input token count not captured by Conduit
                outputTokens: message.metadata?.tokenCount ?? 0,
                totalCost: nil,                                   // TODO: cost not captured by Conduit
                systemFingerprint: nil,                           // TODO: not tracked in RTSMessageMetadata
                latency: message.metadata?.generationTime ?? 0
            )
        }
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
        switch self.content {
        case .text(let string):
            content = RTSGeneratedContent(kind: .string(string))
        case .parts:
            // TODO: map ContentPart array (tool calls, images) to structured RTSGeneratedContent
            content = RTSGeneratedContent(kind: .string(self.content.textValue))
        }
        return RTSFlowGraphMessage(role: role.rawValue, content: content)
    }
}
