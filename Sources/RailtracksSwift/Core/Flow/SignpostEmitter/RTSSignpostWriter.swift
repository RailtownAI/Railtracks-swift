//
//  RTSSignpostWriter.swift
//  RailtracksSwift
//

import Combine
import Foundation
import Synchronization

/// Emits a flow's Instruments signposts from its internal event stream, the only caller of
/// ``RTSSignpostEmitting``.
///
/// One per flow, built in `RTSFlow.init` when the flow emits events and signposts, and subscribed
/// to ``RTSEventEmitter/observedEventPublisher`` for the flow's lifetime:
/// - the executing signal begins a node's Node Runs interval, and `node.destruction` ends it;
/// - `node.invocation` gives its Flow Graph point;
/// - `node.destruction` gives its Tool I/O rows for the edge, then its Flow Tree point and its
///   messages' Tool I/O rows.
///
/// Runs on the emitter's delivery queue, with no `receive(on:)`: an interval is stamped when
/// `begin` or `end` is called, so a hop would make every interval late. Its work there is bounded:
/// a table update and the signpost calls. The tree and message points need a pricing lookup for
/// their cost, so they go out from a detached task; they carry their start time as a field, so
/// arriving later doesn't move them. See docs/signposts-from-events.md.
final class RTSSignpostWriter: Sendable {
    /// What the writer knows about a node between its `node.creation` and `node.destruction`.
    private struct Node {
        let creation: RTSNodeCreationEvent
        let runScope: UUID?
        /// The calling invocation's id, or `nil` at the flow root.
        var parentNodeID: String?
        var runID: RTSRunID?
        /// The id of the edge into the node, which its Tool I/O rows are named after: the run id
        /// for the root, which is the trace's root edge id, and a fresh one otherwise.
        var edgeID: UUID?
        /// `node.invocation`'s `kwargs`, then each input guard transform in turn: the input the
        /// node's body received.
        var input: RTSInput = [:]
        /// The call's messages, from its latest `llm.response` or `llm.failure`.
        var messages: [RTSMessage] = []
        var hasBegun = false
    }

    /// One run's numbering, shared by its Tool I/O rows.
    private struct Run {
        /// The root's run id, which every point of the run carries as its `runID`.
        let rootRunID: RTSRunID
        var ioIndex = 0
    }

    private struct State {
        var nodes: [String: Node] = [:]
        /// Keyed by run scope. Invocations outside `RTSFlow.run`, as in tests, share the `nil` key.
        var runs: [UUID?: Run] = [:]
    }

    /// What a finished node's points need, taken from the table under the lock.
    private struct Finished {
        let nodeID: String
        let node: Node
        let parent: Node?
        let ancestors: [String]
        let run: Run?
    }

    private let sessionID: UUID
    private let signpostEmitter: any RTSSignpostEmitting
    private let state = Mutex(State())

    init(sessionID: UUID, signpostEmitter: any RTSSignpostEmitting) {
        self.sessionID = sessionID
        self.signpostEmitter = signpostEmitter
    }

    func subscribe(to publisher: AnyPublisher<RTSObservedEvent, Never>) -> AnyCancellable {
        publisher.sink { [self] observed in
            write(observed)
        }
    }

    private func write(_ observed: RTSObservedEvent) {
        switch observed.event {
        case .nodeExecuting(let signal):
            begin(signal.nodeID.uuidString)
        case .observability(let event):
            switch event {
            case let creation as RTSNodeCreationEvent:
                state.withLock { state in
                    state.nodes[creation.nodeID] = Node(
                        creation: creation,
                        runScope: observed.runScope
                    )
                }
            case let invocation as RTSNodeInvocationEvent:
                invoke(invocation)
            case let response as RTSGuardInputResponseEvent:
                guard case .nodeAndMiddleware(let nodeID, _) = response.spatialParent,
                      let transformed = response.decision.transformedDictionary else {
                    return
                }
                updateNode(nodeID) { node in
                    node.input = transformed
                }
            case let response as RTSLLMResponseEvent:
                // Each response's input is every message before its output, so the latest one
                // holds the whole call so far.
                guard case .node(let nodeID?) = response.spatialParent else {
                    return
                }
                updateNode(nodeID) { node in
                    node.messages = response.messageInput + (response.output.map { [$0] } ?? [])
                }
            case let failure as RTSLLMFailureEvent:
                // A failure's input is everything the call had accumulated when it threw.
                guard case .node(let nodeID?) = failure.spatialParent else {
                    return
                }
                updateNode(nodeID) { node in
                    node.messages = failure.messageInput
                }
            case let destruction as RTSNodeDestructionEvent:
                finish(destruction)
            default:
                break
            }
        }
    }

    private func updateNode(_ nodeID: String, _ update: (inout Node) -> Void) {
        state.withLock { state in
            guard var node = state.nodes[nodeID] else {
                return
            }
            update(&node)
            state.nodes[nodeID] = node
        }
    }

    // MARK: - Invocation: the graph point

    private func invoke(_ invocation: RTSNodeInvocationEvent) {
        guard case .node(let nodeID) = invocation.parent,
              case .node(let parentNodeID) = invocation.spatialParent,
              let runID = invocation.runID else {
            return
        }
        let invoked = state.withLock { state -> (node: Node, parent: Node?, run: Run)? in
            guard var node = state.nodes[nodeID] else {
                return nil
            }
            node.parentNodeID = parentNodeID
            node.runID = runID
            node.edgeID = parentNodeID == nil ? runID : UUID()
            node.input = invocation.kwargs
            state.nodes[nodeID] = node
            if parentNodeID == nil {
                state.runs[node.runScope] = Run(rootRunID: runID)
            }
            guard let run = state.runs[node.runScope] else {
                return nil
            }
            return (node, parentNodeID.flatMap { state.nodes[$0] }, run)
        }
        guard let invoked else {
            log.warning("⚠️🚧 node.invocation with no node.creation or run before it")
            return
        }
        signpostEmitter.emitGraphNode(
            nodeID: nodeID,
            parentID: parentNodeID ?? "",
            sessionID: sessionID.uuidString,
            runID: invoked.run.rootRunID.uuidString,
            nodeType: invoked.node.creation.nodeType,
            parentType: invoked.parent?.creation.nodeType,
            error: false,
            parentError: false,
            cost: 0,
            model: "",
            parentName: invoked.parent?.creation.name ?? "",
            name: invoked.node.creation.name,
            startTime: invoked.node.creation.timestamp.timeIntervalSince1970
        )
    }

    // MARK: - Executing signal: the interval begins

    private func begin(_ nodeID: String) {
        let begun = state.withLock { state -> (node: Node, parentName: String)? in
            guard var node = state.nodes[nodeID], node.runID != nil else {
                return nil
            }
            node.hasBegun = true
            state.nodes[nodeID] = node
            let parentName = node.parentNodeID.flatMap { state.nodes[$0] }?.creation.name ?? ""
            return (node, parentName)
        }
        guard let begun,
              let invocationID = UUID(uuidString: nodeID),
              let runID = begun.node.runID else {
            log.warning("⚠️🚧 executing signal for a node the writer never saw invoked")
            return
        }
        let creation = begun.node.creation
        signpostEmitter.emitNodeStart(
            nodeID: invocationID,
            parentNodeID: begun.node.parentNodeID.flatMap(UUID.init(uuidString:)),
            nodeName: creation.name,
            nodeType: creation.nodeType,
            sessionID: sessionID,
            parentName: begun.parentName,
            runID: runID,
            input: begun.node.input,
            // The input is the agent's whole `inputs` once its guardrails ran, so this is the
            // system message `invoke` sets.
            instructions: creation.nodeType == .agent
                ? RTSAgentInput.systemMessage(in: begun.node.input)
                : nil,
            hasInputGuardrail: creation.hasInputGuardrail,
            hasOutputGuardrail: creation.hasOutputGuardrail
        )
    }

    // MARK: - Destruction: the interval ends, then the points

    private func finish(_ destruction: RTSNodeDestructionEvent) {
        guard case .node(let nodeID) = destruction.parent else {
            return
        }
        let finished = state.withLock { state -> Finished? in
            guard let node = state.nodes.removeValue(forKey: nodeID) else {
                return nil
            }
            // Children finish before their parent, so the whole chain is still in the table.
            var ancestors: [String] = []
            var ancestorID = node.parentNodeID
            while let currentID = ancestorID, let ancestor = state.nodes[currentID] {
                ancestors.insert(ancestor.creation.name, at: 0)
                ancestorID = ancestor.parentNodeID
            }
            let run = state.runs[node.runScope]
            return Finished(
                nodeID: nodeID,
                node: node,
                parent: node.parentNodeID.flatMap { state.nodes[$0] },
                ancestors: ancestors,
                run: run
            )
        }
        guard let finished,
              let invocationID = UUID(uuidString: nodeID),
              let runID = finished.node.runID,
              let edgeID = finished.node.edgeID,
              let run = finished.run else {
            log.warning("⚠️🚧 node.destruction for a node the writer never saw invoked")
            return
        }
        let output: RTSOutput?
        if destruction.failure == nil, case .object(let response)? = destruction.response {
            output = response
        } else {
            output = nil
        }

        let creation = finished.node.creation
        if finished.node.hasBegun {
            signpostEmitter.emitNodeEnd(
                nodeID: invocationID,
                nodeName: creation.name,
                nodeType: creation.nodeType,
                sessionID: sessionID,
                parentName: finished.parent?.creation.name ?? "",
                runID: runID,
                output: output,
                error: destruction.error
            )
        } else {
            log.warning("⚠️🚧 node.destruction for \(creation.name) with no executing signal before it")
        }

        let point = PointContext(
            nodeID: nodeID,
            sessionID: sessionID.uuidString,
            runID: run.rootRunID.uuidString,
            creation: creation,
            startTime: creation.timestamp.timeIntervalSince1970
        )
        emitEdgeIO(
            point,
            edgeID: edgeID,
            input: finished.node.input,
            output: output,
            failed: destruction.failure != nil,
            runScope: finished.node.runScope
        )
        emitTreeAndMessages(
            point,
            messages: finished.node.messages,
            latency: destruction.timestamp.timeIntervalSince(creation.timestamp),
            failed: destruction.failure != nil,
            ancestors: finished.ancestors,
            runScope: finished.node.runScope
        )
        // The root finishes last, so its run's numbering is done.
        if finished.node.parentNodeID == nil {
            state.withLock { state in
                _ = state.runs.removeValue(forKey: finished.node.runScope)
            }
        }
    }

    /// What every point of one finished node shares.
    private struct PointContext: Sendable {
        let nodeID: String
        let sessionID: String
        let runID: String
        let creation: RTSNodeCreationEvent
        let startTime: TimeInterval
    }

    /// Reserves `count` Tool I/O indices in the node's run and returns the first.
    private func reserveIOIndices(_ count: Int, runScope: UUID?) -> Int {
        state.withLock { state in
            let first = (state.runs[runScope]?.ioIndex ?? 0) + 1
            state.runs[runScope]?.ioIndex += count
            return first
        }
    }

    /// The edge's Tool I/O rows: one per input kwarg, then one per output key for a tool or
    /// function, or a single success or failure row for an agent.
    private func emitEdgeIO(
        _ point: PointContext,
        edgeID: UUID,
        input: RTSInput,
        output: RTSOutput?,
        failed: Bool,
        runScope: UUID?
    ) {
        let outputRows: [(role: String, content: String)]
        switch point.creation.nodeType {
        case .tool, .function:
            let output = output ?? [:]
            outputRows = output.keys.sorted().map { ($0, (output[$0] ?? .null).signpostText) }
        case .agent:
            outputRows = [("result", failed ? "Failed" : "Success")]
        }
        let inputKeys = input.keys.sorted()
        var ioIndex = reserveIOIndices(inputKeys.count + outputRows.count, runScope: runScope) - 1

        for key in inputKeys {
            ioIndex += 1
            emitIO(
                point,
                messageID: "\(edgeID.uuidString)-kwarg-\(key)",
                source: "edge",
                direction: "Input",
                role: "kwarg:\(key)",
                model: point.creation.model,
                provider: point.creation.provider,
                latency: 0,
                inputTokens: 0,
                outputTokens: 0,
                cost: 0,
                displayRole: "\(String(format: "%03d", ioIndex)) kwarg:\(key)",
                content: (input[key] ?? .null).signpostText
            )
        }
        for row in outputRows {
            ioIndex += 1
            emitIO(
                point,
                messageID: "\(edgeID.uuidString)-out\(ioIndex)",
                source: "edge",
                direction: "Output",
                role: row.role,
                model: point.creation.model,
                provider: point.creation.provider,
                latency: 0,
                inputTokens: 0,
                outputTokens: 0,
                cost: 0,
                displayRole: "\(String(format: "%03d", ioIndex)) \(row.role)",
                content: row.content
            )
        }
    }

    /// The node's Flow Tree point and one Tool I/O row per message, from a detached task, since
    /// each needs a pricing lookup for its cost.
    private func emitTreeAndMessages(
        _ point: PointContext,
        messages: [RTSMessage],
        latency: TimeInterval,
        failed: Bool,
        ancestors: [String],
        runScope: UUID?
    ) {
        let metadata = messages.compactMap(\.metadata)
        let inputTokens = metadata.compactMap(\.inputTokenCount).reduce(0, +)
        let outputTokens = metadata.compactMap(\.tokenCount).reduce(0, +)
        let model = metadata.last?.model ?? ""
        let provider = metadata.last?.providerName ?? ""

        // Numbered now, in delivery order, so the rows keep their place among the edge rows.
        var ioIndex = reserveIOIndices(messages.count, runScope: runScope) - 1
        let rows = messages.sorted { $0.timestamp < $1.timestamp }.map { message in
            ioIndex += 1
            let isInput = message.role == .system || message.role == .user
            let messageMetadata = message.metadata
            return PendingMessageIO(
                messageID: message.id.uuidString,
                direction: isInput ? "Input" : "Output",
                role: message.role.rawValue,
                model: messageMetadata?.model ?? model,
                provider: messageMetadata?.providerName ?? provider,
                latency: isInput ? 0 : (messageMetadata?.generationTime ?? 0),
                inputTokens: isInput ? 0 : (messageMetadata?.inputTokenCount ?? 0),
                outputTokens: isInput ? 0 : (messageMetadata?.tokenCount ?? 0),
                displayRole: "\(String(format: "%03d", ioIndex)) \(message.role.rawValue)",
                content: message.content.textValue
            )
        }

        Task.detached { [self] in
            let nodeCost = await Self.cost(
                model: model,
                provider: provider,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
            signpostEmitter.emitTreeNode(
                nodeID: point.nodeID,
                sessionID: point.sessionID,
                runID: point.runID,
                nodeType: point.creation.nodeType,
                model: model,
                provider: provider,
                cost: nodeCost,
                latency: latency,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                error: failed,
                ancestors: ancestors,
                name: point.creation.name,
                startTime: point.startTime,
                hasInputGuardrail: point.creation.hasInputGuardrail,
                hasOutputGuardrail: point.creation.hasOutputGuardrail
            )
            for row in rows {
                let rowCost = await Self.cost(
                    model: row.model,
                    provider: row.provider,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens
                )
                emitIO(
                    point,
                    messageID: row.messageID,
                    source: "llm",
                    direction: row.direction,
                    role: row.role,
                    model: row.model,
                    provider: row.provider,
                    latency: row.latency,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    cost: rowCost,
                    displayRole: row.displayRole,
                    content: row.content
                )
            }
        }
    }

    private func emitIO(
        _ point: PointContext,
        messageID: String,
        source: String,
        direction: String,
        role: String,
        model: String,
        provider: String,
        latency: TimeInterval,
        inputTokens: Int,
        outputTokens: Int,
        cost: Double,
        displayRole: String,
        content: String
    ) {
        signpostEmitter.emitIO(
            nodeID: point.nodeID,
            sessionID: point.sessionID,
            runID: point.runID,
            messageID: messageID,
            source: source,
            direction: direction,
            role: role,
            model: model,
            provider: provider,
            cost: cost,
            latency: latency,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            displayRole: displayRole,
            toolName: point.creation.name,
            content: content,
            startTime: point.startTime,
            hasInputGuardrail: point.creation.hasInputGuardrail,
            hasOutputGuardrail: point.creation.hasOutputGuardrail
        )
    }

    /// USD cost from token usage via `RTSCostCalculator`, the way the trace's `llm_details` gets
    /// it. 0 for local providers (AppleAI), when no tokens were used, or when the model has no
    /// pricing entry or the pricing map is unavailable.
    static func cost(
        model: String,
        provider: String,
        inputTokens: Int,
        outputTokens: Int
    ) async -> Double {
        guard !RTSLLMProvider.isLocal(providerName: provider),
              inputTokens > 0 || outputTokens > 0 else {
            return 0
        }
        let usage = RTSTokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)
        let cost = try? await RTSCostCalculator.shared.calculateCost(model: model, usage: usage)
        return cost?.totalCost ?? 0
    }
}

/// One message's Tool I/O fields, built on the delivery queue with its index reserved, so the
/// detached task carries no message.
private struct PendingMessageIO: Sendable {
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
