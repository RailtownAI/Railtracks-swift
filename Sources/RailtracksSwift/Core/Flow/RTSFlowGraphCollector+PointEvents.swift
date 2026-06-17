//
//  RTSFlowGraphCollector+PointEvents.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-08.
//

import Foundation

// MARK: - Point event emission

extension RTSFlowGraphCollector {
    /// Emits `FlowGraphNode`, `FlowTreeNode`, and `FlowIO` for a finishing node.
    /// Called from `processNodeEvent` after the message buffer has been flushed,
    /// so `nodeEvent.messages` is complete and all ancestor edge events are
    /// already in `edgeEvents`.
    func emitNodePointEvents(_ nodeEvent: RTSNodeEvent) {
        guard let signpostEmitter else { return }
        guard let runID = nodeEvent.runID else { return }

        let nodeIDStr = nodeEvent.id.uuidString
        let sessionIDStr = sessionID.uuidString
        let runIDStr = rootRunID?.uuidString ?? runID.uuidString
        let hasError = nodeEvent.error != nil

        // Latency: difference between the node's create and finish stamps
        let createStamp = nodeEvents
            .first(where: { $0.id == nodeEvent.id && $0.runID == nil })?.stamp.timestamp
        let latency = createStamp.map { nodeEvent.stamp.timestamp.timeIntervalSince($0) } ?? 0

        // Aggregate LLM metadata from messages that carry it
        let messagesWithMeta: [(RTSMessage, RTSMessageMetadata)] = nodeEvent.messages
            .compactMap {
                guard let meta = $0.metadata else { return nil }
                return ($0, meta)
            }
        let totalInputTokens = messagesWithMeta.compactMap { $0.1.inputTokenCount }.reduce(0, +)
        let totalOutputTokens = messagesWithMeta.compactMap { $0.1.tokenCount }.reduce(0, +)
        let lastMeta = messagesWithMeta.last?.1
        let model = lastMeta?.model ?? ""
        let provider = lastMeta?.providerName ?? ""

        log.debug("🌲 emitTreeNode '\(nodeEvent.name)': messages=\(nodeEvent.messages.count) messagesWithMeta=\(messagesWithMeta.count) model='\(model)' provider='\(provider)' inputTokens=\(totalInputTokens) outputTokens=\(totalOutputTokens)")

        // Ancestor chain: walk edgeEvents upward from this node to the root
        let ancestorChain = buildAncestors(for: nodeEvent.id)

        let nodeStartTime = createStamp?.timeIntervalSince1970 ?? 0
        signpostEmitter.emitTreeNode(
            nodeID: nodeIDStr,
            sessionID: sessionIDStr,
            runID: runIDStr,
            nodeType: nodeEvent.nodeType,
            model: model,
            provider: provider,
            cost: 0,
            latency: latency,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            error: hasError,
            ancestors: ancestorChain,
            name: nodeEvent.name,
            startTime: nodeStartTime
        )

        // FlowIO — one event per LLM message, numbered per direction bucket
        var inputIdx = 0
        var outputIdx = 0
        for message in nodeEvent.messages {
            let isInput = message.role == .system || message.role == .user
            let direction = isInput ? "Input" : "Output"
            if isInput { inputIdx += 1 } else { outputIdx += 1 }
            let idx = isInput ? inputIdx : outputIdx
            let displayRole = "\(String(format: "%02d", idx)) \(message.role.rawValue)"
            let meta = message.metadata

            log.trace("🎁 emitIO: '\(nodeEvent.name)' direction=\(direction) role=\(message.role.rawValue) nodeID=\(nodeIDStr)")
            signpostEmitter.emitIO(
                nodeID: nodeIDStr,
                sessionID: sessionIDStr,
                runID: runIDStr,
                messageID: message.id.uuidString,
                source: "llm",
                direction: direction,
                role: message.role.rawValue,
                model: meta?.model ?? model,
                provider: meta?.providerName ?? provider,
                cost: 0,
                latency: isInput ? 0 : (meta?.generationTime ?? 0),
                inputTokens: isInput ? 0 : (meta?.inputTokenCount ?? 0),
                outputTokens: isInput ? 0 : (meta?.tokenCount ?? 0),
                displayRole: displayRole,
                toolName: nodeEvent.name,
                content: message.content.textValue,
                startTime: nodeStartTime
            )
        }
    }

    /// Emits `FlowIO` events for edge-level tool input kwargs and output.
    /// Called for every edge finish — by that point the target node's create
    /// event is already in `nodeEvents` so an accurate `startTime` is available.
    func emitEdgePointEvents(_ edgeEvent: RTSEdgeEvent) {
        guard let signpostEmitter else { return }

        let targetIDStr = edgeEvent.targetNodeID.uuidString
        let sessionIDStr = sessionID.uuidString
        let runIDStr = rootRunID?.uuidString ?? edgeEvent.runID?.uuidString ?? edgeEvent.id.uuidString
        let toolName = edgeEvent.targetName
        let edgeIDStr = edgeEvent.id.uuidString

        let targetCreateStamp = nodeEvents
            .first(where: { $0.id == edgeEvent.targetNodeID && $0.runID == nil })?.stamp.timestamp
        let startTime = targetCreateStamp?.timeIntervalSince1970 ?? 0

        let targetFinishMessages = nodeEvents
            .first(where: { $0.id == edgeEvent.targetNodeID && $0.runID != nil })?.messages ?? []
        let lastMeta = targetFinishMessages.compactMap(\.metadata).last
        let model = lastMeta?.model ?? ""
        let provider = lastMeta?.providerName ?? ""

        var inputIdx = 0
        let input = edgeEvent.input ?? [:]
        for key in input.keys.sorted() {
            inputIdx += 1
            signpostEmitter.emitIO(
                nodeID: targetIDStr,
                sessionID: sessionIDStr,
                runID: runIDStr,
                messageID: "\(edgeIDStr)-kwarg-\(key)",
                source: "edge",
                direction: "Input",
                role: "kwarg:\(key)",
                model: model,
                provider: provider,
                cost: 0,
                latency: 0,
                inputTokens: 0,
                outputTokens: 0,
                displayRole: "\(String(format: "%02d", inputIdx)) kwarg:\(key)",
                toolName: toolName,
                content: stringify(input[key] ?? .null),
                startTime: startTime
            )
        }

        let outputRows: [(role: String, content: String)]
        switch edgeEvent.nodeType {
        case .tool:
            let output = edgeEvent.output ?? [:]
            outputRows = output.keys.sorted().map { ($0, stringify(output[$0] ?? .null)) }
        case .agent:
            outputRows = [("result", edgeEvent.error == nil ? "Success" : "Failed")]
        }

        for (i, row) in outputRows.enumerated() {
            signpostEmitter.emitIO(
                nodeID: targetIDStr,
                sessionID: sessionIDStr,
                runID: runIDStr,
                messageID: "\(edgeIDStr)-out\(i)",
                source: "edge",
                direction: "Output",
                role: row.role,
                model: model,
                provider: provider,
                cost: 0,
                latency: 0,
                inputTokens: 0,
                outputTokens: 0,
                displayRole: "\(String(format: "%02d", i + 1)) \(row.role)",
                toolName: toolName,
                content: row.content,
                startTime: startTime
            )
        }
    }

    private func stringify(_ value: RTSValue) -> String {
        switch value {
        case .null:           return "null"
        case .bool(let b):   return b ? "true" : "false"
        case .number(let n): return "\(n)"
        case .string(let s): return s
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value),
                  let str = String(data: data, encoding: .utf8) else { return "\(value)" }
            return str
        }
    }

    /// Walk `edgeEvents` upward from `nodeID` to the root, collecting ancestor
    /// names in root-first order. Stops when no incoming non-root edge is found.
    private func buildAncestors(for nodeID: UUID) -> [String] {
        var result: [String] = []
        var currentID = nodeID
        while let edge = edgeEvents
            .first(where: { $0.targetNodeID == currentID && $0.sourceNodeID != nil }),
              let sourceName = edge.sourceName,
              let sourceID = edge.sourceNodeID {
            result.insert(sourceName, at: 0)
            currentID = sourceID
        }
        return result
    }
}
