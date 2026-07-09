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
    func emitNodePointEvents(_ nodeEvent: RTSNodeEvent) async {
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

        log.debug("🌊 emitNodePointEvents emitTreeNode '\(nodeEvent.name)': messages=\(nodeEvent.messages.count) messagesWithMeta=\(messagesWithMeta.count) model='\(model)' provider='\(provider)' inputTokens=\(totalInputTokens) outputTokens=\(totalOutputTokens)")

        // Ancestor chain: walk edgeEvents upward from this node to the root
        let ancestorChain = buildAncestors(for: nodeEvent.id)

        let nodeCost = await computeCost(
            model: model,
            provider: provider,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens
        )

        let nodeStartTime = createStamp?.timeIntervalSince1970 ?? 0
        signpostEmitter.emitTreeNode(
            nodeID: nodeIDStr,
            sessionID: sessionIDStr,
            runID: runIDStr,
            nodeType: nodeEvent.nodeType,
            model: model,
            provider: provider,
            cost: nodeCost,
            latency: latency,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            error: hasError,
            ancestors: ancestorChain,
            name: nodeEvent.name,
            startTime: nodeStartTime,
            hasInputGuardrail: nodeEvent.hasInputGuardrail,
            hasOutputGuardrail: nodeEvent.hasOutputGuardrail
        )

        // FlowIO — one event per LLM message, continuing the global IO counter
        let sortedMessages = nodeEvent.messages.sorted { $0.timestamp < $1.timestamp }
        for message in sortedMessages {
            ioIndex += 1
            let isInput = message.role == .system || message.role == .user
            let direction = isInput ? "Input" : "Output"
            let displayRole = "\(String(format: "%03d", ioIndex)) \(message.role.rawValue)"
            let meta = message.metadata
            let messageInputTokens = isInput ? 0 : (meta?.inputTokenCount ?? 0)
            let messageOutputTokens = isInput ? 0 : (meta?.tokenCount ?? 0)
            let messageCost = await computeCost(
                model: meta?.model ?? model,
                provider: meta?.providerName ?? provider,
                inputTokens: messageInputTokens,
                outputTokens: messageOutputTokens
            )

            log.debug("🌊 emitIO[llm] '\(nodeEvent.name)' dir=\(direction) role=\(message.role.rawValue) contentLen=\(message.content.textValue.count) startTime=\(nodeStartTime)")
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
                cost: messageCost,
                latency: isInput ? 0 : (meta?.generationTime ?? 0),
                inputTokens: messageInputTokens,
                outputTokens: messageOutputTokens,
                displayRole: displayRole,
                toolName: nodeEvent.name,
                content: message.content.textValue,
                startTime: nodeStartTime,
                hasInputGuardrail: nodeEvent.hasInputGuardrail,
                hasOutputGuardrail: nodeEvent.hasOutputGuardrail
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

        // provider/model are stored on the node create event, which is always in nodeEvents
        // by the time edge finish fires (node create precedes edge create in invokeCore).
        let nodeCreateEvent = nodeEvents
            .first(where: { $0.id == edgeEvent.targetNodeID && $0.runID == nil })
        let model = nodeCreateEvent?.model ?? ""
        let provider = nodeCreateEvent?.provider ?? ""
        let hasInputGuardrail = nodeCreateEvent?.hasInputGuardrail ?? false
        let hasOutputGuardrail = nodeCreateEvent?.hasOutputGuardrail ?? false

        log.debug("🌊 emitEdgePointEvents '\(edgeEvent.targetName)': model='\(model)' provider='\(provider)'")

        let input = edgeEvent.input ?? [:]
        for key in input.keys.sorted() {
            ioIndex += 1
            let kwargContent = stringify(input[key] ?? .null)
            log.debug("🌊 emitIO[edge-in] '\(edgeEvent.targetName)' kwarg=\(key) contentLen=\(kwargContent.count) startTime=\(startTime)")
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
                displayRole: "\(String(format: "%03d", ioIndex)) kwarg:\(key)",
                toolName: toolName,
                content: kwargContent,
                startTime: startTime,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            )
        }

        let outputRows: [(role: String, content: String)]
        switch edgeEvent.nodeType {
        case .tool, .function:
            let output = edgeEvent.output ?? [:]
            outputRows = output.keys.sorted().map { ($0, stringify(output[$0] ?? .null)) }
        case .agent:
            outputRows = [("result", edgeEvent.error == nil ? "Success" : "Failed")]
        }

        for (_, row) in outputRows.enumerated() {
            ioIndex += 1
            log.debug("🌊 emitIO[edge-out] '\(edgeEvent.targetName)' role=\(row.role) contentLen=\(row.content.count) startTime=\(startTime)")
            signpostEmitter.emitIO(
                nodeID: targetIDStr,
                sessionID: sessionIDStr,
                runID: runIDStr,
                messageID: "\(edgeIDStr)-out\(ioIndex)",
                source: "edge",
                direction: "Output",
                role: row.role,
                model: model,
                provider: provider,
                cost: 0,
                latency: 0,
                inputTokens: 0,
                outputTokens: 0,
                displayRole: "\(String(format: "%03d", ioIndex)) \(row.role)",
                toolName: toolName,
                content: row.content,
                startTime: startTime,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            )
        }
    }

    /// Computes USD cost from token usage via `RTSCostCalculator`, mirroring the
    /// JSON-export path (`RTSFlowGraph+Parser.makeLLMDetails`). Returns 0 for local
    /// providers (e.g. AppleAI, which have no cost), when no tokens were used, or when
    /// the model has no pricing entry / the pricing map is unavailable.
    private func computeCost(
        model: String,
        provider: String,
        inputTokens: Int,
        outputTokens: Int
    ) async -> Double {
        guard !RTSLLMProvider.isLocal(providerName: provider),
              inputTokens > 0 || outputTokens > 0 else { return 0 }
        let usage = RTSTokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)
        let cost = try? await RTSCostCalculator.shared.calculateCost(model: model, usage: usage)
        return cost?.totalCost ?? 0
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
