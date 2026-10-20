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
    /// Synchronous on the actor: it snapshots the state it needs (create stamp, ancestor
    /// chain, token totals) and reserves the shared `ioIndex` range, then hands the async
    /// cost calculation and signpost emission to a detached task. This keeps the JSON-
    /// collection actor path suspension-free — an `await` here would let a reentrant
    /// `finishCollection()` serialize the graph mid-flight and drop nodes. Signposts are
    /// an independent real-time side-channel, so fire-and-forget emission is correct; the
    /// JSON trace's cost is computed separately in the parser and is unaffected.
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

        log.debug("🌊 emitNodePointEvents emitTreeNode '\(nodeEvent.name)': messages=\(nodeEvent.messages.count) messagesWithMeta=\(messagesWithMeta.count) model='\(model)' provider='\(provider)' inputTokens=\(totalInputTokens) outputTokens=\(totalOutputTokens)")

        // Ancestor chain: walk edgeEvents upward from this node to the root
        let ancestorChain = buildAncestors(for: nodeEvent.id)
        let nodeStartTime = createStamp?.timeIntervalSince1970 ?? 0

        // Build per-message IO payloads (synchronously) so ordering stays
        // stable relative to edge IO even though the emit runs off the actor.
        let sortedMessages = nodeEvent.messages.sorted { $0.timestamp < $1.timestamp }
        var ioPayloads: [PendingNodeIO] = []
        for message in sortedMessages {
            ioIndex += 1
            let isInput = message.role == .system || message.role == .user
            let meta = message.metadata
            ioPayloads.append(PendingNodeIO(
                messageID: message.id.uuidString,
                direction: isInput ? "Input" : "Output",
                role: message.role.rawValue,
                model: meta?.model ?? model,
                provider: meta?.providerName ?? provider,
                latency: isInput ? 0 : (meta?.generationTime ?? 0),
                inputTokens: isInput ? 0 : (meta?.inputTokenCount ?? 0),
                outputTokens: isInput ? 0 : (meta?.tokenCount ?? 0),
                displayRole: "\(String(format: "%03d", ioIndex)) \(message.role.rawValue)",
                content: message.content.textValue
            ))
        }

        let name = nodeEvent.name
        let nodeType = nodeEvent.nodeType
        let hasInputGuardrail = nodeEvent.hasInputGuardrail
        let hasOutputGuardrail = nodeEvent.hasOutputGuardrail

        Task.detached { [signpostEmitter] in
            let nodeCost = await Self.computeCost(
                model: model,
                provider: provider,
                inputTokens: totalInputTokens,
                outputTokens: totalOutputTokens
            )
            signpostEmitter.emitTreeNode(
                nodeID: nodeIDStr,
                sessionID: sessionIDStr,
                runID: runIDStr,
                nodeType: nodeType,
                model: model,
                provider: provider,
                cost: nodeCost,
                latency: latency,
                inputTokens: totalInputTokens,
                outputTokens: totalOutputTokens,
                error: hasError,
                ancestors: ancestorChain,
                name: name,
                startTime: nodeStartTime,
                hasInputGuardrail: hasInputGuardrail,
                hasOutputGuardrail: hasOutputGuardrail
            )

            for io in ioPayloads {
                let messageCost = await Self.computeCost(
                    model: io.model,
                    provider: io.provider,
                    inputTokens: io.inputTokens,
                    outputTokens: io.outputTokens
                )
                signpostEmitter.emitIO(
                    nodeID: nodeIDStr,
                    sessionID: sessionIDStr,
                    runID: runIDStr,
                    messageID: io.messageID,
                    source: "llm",
                    direction: io.direction,
                    role: io.role,
                    model: io.model,
                    provider: io.provider,
                    cost: messageCost,
                    latency: io.latency,
                    inputTokens: io.inputTokens,
                    outputTokens: io.outputTokens,
                    displayRole: io.displayRole,
                    toolName: name,
                    content: io.content,
                    startTime: nodeStartTime,
                    hasInputGuardrail: hasInputGuardrail,
                    hasOutputGuardrail: hasOutputGuardrail
                )
            }
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
            let kwargContent = (input[key] ?? .null).signpostText
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
            outputRows = output.keys.sorted().map { ($0, (output[$0] ?? .null).signpostText) }
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
    ///
    /// `static` (actor-nonisolated) so the detached signpost-emit task can call it
    /// without re-entering the collector actor — it touches no actor state.
    static func computeCost(
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

/// Sendable snapshot of a single LLM message's FlowIO fields, built synchronously on the
/// actor (with its `ioIndex` slot reserved) so the detached emit task carries no reference
/// to actor state or non-Sendable message types.
private struct PendingNodeIO: Sendable {
    let messageID: String
    let direction: String
    let role: String
    let model: String
    let provider: String
    let latency: TimeInterval
    let inputTokens: Int
    let outputTokens: Int
    let displayRole: String
    let content: String
}
