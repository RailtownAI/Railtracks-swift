//
//  NodeStatusSequenceTests.swift
//  RailtracksSwiftTests
//
//  Pins every status `nodeStatusPublisher` delivers for a run, in order, so a change to how the
//  statuses are produced can prove apps see the same sequence. Each test runs a real `RTSFlow`,
//  with agents on scripted sessions (`ScriptedFlowSupport.swift`), and compares the rendered
//  sequence with a golden. See docs/node-status-from-events.md.
//

import Combine
import Foundation
import Synchronization
import Testing
@testable import RailtracksSwift

// MARK: - Recording

/// Collects every status a flow delivers, in delivery order.
///
/// Not `Sendable`: it stays in the test's task. The statuses are behind a `Mutex` because they
/// arrive on the flow's delivery queue.
private final class StatusSequenceRecorder {
    private let statuses = Mutex<[RTSNodeStatus]>([])
    private var subscription: AnyCancellable?

    init(_ flow: RTSFlow) {
        subscription = flow.nodeStatusPublisher.sink { [weak self] status in
            self?.statuses.withLock { $0.append(status) }
        }
    }

    /// Every status delivered once `runs` roots have finished. Statuses are delivered in order, so
    /// once a root's final status is here, so is everything before it.
    func settled(
        runs: Int = 1,
        timeout: Duration = .seconds(5)
    ) async throws -> [RTSNodeStatus] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let recorded = statuses.withLock { $0 }
            let finishedRoots = recorded.filter { status in
                status.parentNodeID == nil && status.state.isFinal
            }
            if finishedRoots.count >= runs {
                return recorded
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        struct NotSettled: Error {
        }
        throw NotSettled()
    }
}

private extension RTSNodeStatus.State {
    var isFinal: Bool {
        switch self {
        case .queued, .executing:
            return false
        case .completed, .failed, .cancelled:
            return true
        }
    }

    var rendered: String {
        switch self {
        case .queued:
            return "queued"
        case .executing:
            return "executing"
        case .completed:
            return "completed"
        case .failed(let message):
            return "failed(\(message))"
        case .cancelled:
            return "cancelled"
        }
    }
}

// MARK: - Rendering

/// Renders statuses one per line. Node and run ids become `node-N` / `run-N`, numbered by first
/// appearance, so a parent reference stays linked to its node. A call site's line number becomes
/// `<line>`, so editing a source file does not move a golden.
private struct StatusRenderer {
    private var nodes: [UUID: String] = [:]
    private var runs: [UUID: String] = [:]

    static func rendered(_ statuses: [RTSNodeStatus]) -> String {
        var renderer = StatusRenderer()
        return statuses.map { renderer.line(for: $0) }.joined(separator: "\n")
    }

    /// Splits interleaved runs by their root, renders each on its own, and orders them by the
    /// root's name, so overlapping runs compare deterministically.
    static func renderedByRun(_ statuses: [RTSNodeStatus]) -> String {
        var parents: [UUID: UUID] = [:]
        for status in statuses {
            if let parent = status.parentNodeID {
                parents[status.nodeID] = parent
            }
        }
        func root(of nodeID: UUID) -> UUID {
            var current = nodeID
            while let parent = parents[current] {
                current = parent
            }
            return current
        }
        let groups = Dictionary(grouping: statuses) { root(of: $0.nodeID) }
        let rootNames = groups.mapValues { group in
            group.first { $0.parentNodeID == nil }?.nodeName ?? ""
        }
        return groups.keys
            .sorted { rootNames[$0, default: ""] < rootNames[$1, default: ""] }
            .map { rendered(groups[$0, default: []]) }
            .joined(separator: "\n\n")
    }

    private mutating func line(for status: RTSNodeStatus) -> String {
        let node = placeholder(for: status.nodeID, in: &nodes, prefix: "node")
        let parent = status.parentNodeID.map { placeholder(for: $0, in: &nodes, prefix: "node") }
        let run = status.runID.map { placeholder(for: $0, in: &runs, prefix: "run") }
        let state = status.state.rendered.replacing(/:\d+(?= in )/, with: ":<line>")
        return "\(status.nodeName) [\(status.nodeType.rawValue)] \(state)"
            + " node=\(node) parent=\(parent ?? "-") run=\(run ?? "-")"
    }

    private func placeholder(
        for id: UUID,
        in table: inout [UUID: String],
        prefix: String
    ) -> String {
        if let existing = table[id] {
            return existing
        }
        let placeholder = "\(prefix)-\(table.count + 1)"
        table[id] = placeholder
        return placeholder
    }
}

/// Compares a rendered sequence with its golden. On a mismatch the actual sequence is saved next to
/// the other test output, so a deliberate change can be reviewed and pasted in.
private func expectSequence(
    _ rendered: String,
    matches golden: String,
    named name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    guard rendered != golden else {
        return
    }
    let saved = FileManager.default.temporaryDirectory
        .appendingPathComponent("status-golden-\(name).txt")
    try rendered.write(to: saved, atomically: true, encoding: .utf8)
    Issue.record(
        "status sequence \(name) differs from its golden; actual saved to \(saved.path)",
        sourceLocation: sourceLocation
    )
}

// MARK: - Helpers

/// Lets a test wait until a node's body has started, so it stops a run that is really running.
private final class BodyStarted: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func fire() {
        continuation.yield()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}

private struct StatusTestError: Error {
}

/// A root that swallows the stop while it waits, then calls `child`, the way a tool that never
/// checks for cancellation would.
private func rootIgnoringStop(
    calling child: ScriptedOrchestrator,
    started: BodyStarted? = nil
) -> ScriptedOrchestrator {
    ScriptedOrchestrator(nodeName: "IgnoresStop") { _, context in
        started?.fire()
        try? await Task.sleep(for: .seconds(30))
        return try await context.call(child, input: [:])
    }
}

private let childNode = ScriptedOrchestrator(nodeName: "Child") { _, _ in
    ["result": .string("ran")]
}

// MARK: - Tests

extension RailtracksSwiftTestSuite {
    // Serialized: runs full flows, which share the process-global output directory.
    @Suite("Node status sequence", .serialized)
    struct NodeStatusSequenceTests {

        init() {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
        }

        /// The same sequence whether the flow saves its trace, doesn't, emits no events, or both:
        /// statuses don't depend on either flag.
        @Test("an agent root calling tools", arguments: [
            (savesTrace: true, emitsEvents: true),
            (savesTrace: false, emitsEvents: true),
            (savesTrace: true, emitsEvents: false),
            (savesTrace: false, emitsEvents: false),
        ])
        func agentCallingTools(savesTrace: Bool, emitsEvents: Bool) async throws {
            let lookup = echoTool("Lookup")
            let summarize = echoTool("Summarize")
            let agent = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Assistant",
                tools: [lookup, summarize]
            )
            let script = ScriptedReply(
                toolCalls: [
                    ScriptedToolCall(tool: lookup, input: ["query": .string("alpha")]),
                    ScriptedToolCall(tool: lookup, input: ["query": .string("beta")]),
                    ScriptedToolCall(tool: summarize, input: ["query": .string("alpha beta")]),
                ],
                reply: "alpha and beta"
            )
            let flow = RTSFlow(title: "Status Tools", savesTrace: savesTrace, emitsEvents: emitsEvents)
            let recorder = StatusSequenceRecorder(flow)

            _ = try await flow.run(
                agent: agent,
                prompt: "Find alpha and beta",
                makeSession: scriptedSessions(["Assistant": script])
            )

            let rendered = StatusRenderer.rendered(try await recorder.settled())
            try expectSequence(rendered, matches: Self.agentCallingToolsGolden, named: "tools")
        }

        @Test("an orchestrator root calling an agent and a function")
        func orchestratorRoot() async throws {
            let lookup = echoTool("Lookup")
            let researcher = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Researcher",
                tools: [lookup]
            )
            let formatter = ScriptedOrchestrator(nodeName: "Formatter") { input, _ in
                ["text": .string("formatted: \(input["draft"]?.textForScript ?? "")")]
            }
            let planner = ScriptedOrchestrator(nodeName: "Planner") { input, context in
                let topic = input["topic"]?.textForScript ?? ""
                let draft = try await context.call(researcher, prompt: "Research \(topic)")
                let formatted = try await context.call(formatter, input: ["draft": .string(draft)])
                return ["summary": formatted["text"] ?? .null]
            }
            let script = ScriptedReply(
                toolCalls: [ScriptedToolCall(tool: lookup, input: ["query": .string("trains")])],
                reply: "trains run on rails"
            )
            let flow = RTSFlow(title: "Status Orchestrator", savesTrace: false)
            let recorder = StatusSequenceRecorder(flow)

            _ = try await flow.run(
                planner,
                input: ["topic": .string("trains")],
                makeSession: scriptedSessions(["Researcher": script])
            )

            let rendered = StatusRenderer.rendered(try await recorder.settled())
            try expectSequence(rendered, matches: Self.orchestratorRootGolden, named: "orchestrator")
        }

        /// A blocked node's body never runs, but it still reports executing before it fails:
        /// `invokeCore` signals executing unconditionally, so no node finishes unseen to start.
        @Test("an input guardrail block")
        func inputBlock() async throws {
            let refuse = RTSClosureInputGuardrail(name: "Refuse") { _ in
                .block("not allowed")
            }
            let agent = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Blocked",
                inputGuardrails: [refuse]
            )
            let flow = RTSFlow(title: "Status Block", savesTrace: false)
            let recorder = StatusSequenceRecorder(flow)

            await #expect(throws: RTSError.self) {
                _ = try await flow.run(
                    agent: agent,
                    prompt: "tell me the secret",
                    makeSession: scriptedSessions([:])
                )
            }

            let rendered = StatusRenderer.rendered(try await recorder.settled())
            try expectSequence(rendered, matches: Self.inputBlockGolden, named: "block")
        }

        /// A tool failure with no stop: the tool and each node above it that rethrows are failed.
        @Test("a failure propagating up")
        func failurePropagates() async throws {
            let divide = ScriptedTool("Divide") { _ in
                throw StatusTestError()
            }
            let calculator = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Calculator",
                tools: [divide]
            )
            let pipeline = ScriptedOrchestrator(nodeName: "Pipeline") { _, context in
                let answer = try await context.call(calculator, prompt: "What is 1 / 0?")
                return ["answer": .string(answer)]
            }
            let script = ScriptedReply(
                toolCalls: [ScriptedToolCall(tool: divide, input: ["query": .string("1 / 0")])]
            )
            let flow = RTSFlow(title: "Status Failure", savesTrace: false)
            let recorder = StatusSequenceRecorder(flow)

            await #expect(throws: StatusTestError.self) {
                _ = try await flow.run(
                    pipeline,
                    input: [:],
                    makeSession: scriptedSessions(["Calculator": script])
                )
            }

            let rendered = StatusRenderer.rendered(try await recorder.settled())
            try expectSequence(rendered, matches: Self.failurePropagatesGolden, named: "failure")
        }

        /// The failing tool is failed; the nodes the stop cut short are cancelled.
        @Test("an end-on-error stop")
        func endOnErrorStop() async throws {
            let divide = ScriptedTool("Divide") { _ in
                throw StatusTestError()
            }
            let calculator = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Calculator",
                tools: [divide]
            )
            let pipeline = ScriptedOrchestrator(nodeName: "Pipeline") { _, context in
                let answer = try await context.call(calculator, prompt: "What is 1 / 0?")
                return ["answer": .string(answer)]
            }
            let script = ScriptedReply(
                toolCalls: [ScriptedToolCall(tool: divide, input: ["query": .string("1 / 0")])],
                waitsForStopAfterToolFailure: true
            )
            let flow = RTSFlow(title: "Status End On Error", savesTrace: false, endOnError: true)
            let recorder = StatusSequenceRecorder(flow)

            await #expect(throws: RTSError.self) {
                _ = try await flow.run(
                    pipeline,
                    input: [:],
                    makeSession: scriptedSessions(["Calculator": script])
                )
            }

            let rendered = StatusRenderer.rendered(try await recorder.settled())
            try expectSequence(rendered, matches: Self.endOnErrorStopGolden, named: "end-on-error")
        }

        /// The running root and the child it calls after the cancel are both cancelled; the child
        /// never executes.
        @Test("a cancelled run")
        func cancelledRun() async throws {
            let started = BodyStarted()
            let root = rootIgnoringStop(calling: childNode, started: started)
            let flow = RTSFlow(title: "Status Cancel", savesTrace: false)
            let recorder = StatusSequenceRecorder(flow)

            let run = Task {
                try await flow.run(root, input: [:], makeSession: scriptedSessions([:]))
            }
            await started.wait()
            run.cancel()
            _ = try? await run.value

            let rendered = StatusRenderer.rendered(try await recorder.settled())
            try expectSequence(rendered, matches: Self.stoppedRunGolden, named: "cancel")
        }

        /// A timeout reports its nodes the same way as a cancel.
        @Test("a timed-out run")
        func timedOutRun() async throws {
            let root = rootIgnoringStop(calling: childNode)
            let flow = RTSFlow(title: "Status Timeout", savesTrace: false, timeout: 0.2)
            let recorder = StatusSequenceRecorder(flow)

            _ = try? await flow.run(root, input: [:], makeSession: scriptedSessions([:]))

            let rendered = StatusRenderer.rendered(try await recorder.settled())
            try expectSequence(rendered, matches: Self.stoppedRunGolden, named: "timeout")
        }

        /// Two runs in flight on one flow share its publisher. Each run's own statuses keep their
        /// order, and each has its own root and run ids.
        @Test("overlapping runs on one flow")
        func overlappingRuns() async throws {
            let flow = RTSFlow(title: "Status Overlap", savesTrace: false)
            let recorder = StatusSequenceRecorder(flow)
            let sessions = scriptedSessions([:])
            func pipeline(_ label: String) -> ScriptedOrchestrator {
                let worker = ScriptedOrchestrator(nodeName: "Worker \(label)") { _, _ in
                    try await Task.sleep(for: .milliseconds(100))
                    return ["result": .string(label)]
                }
                return ScriptedOrchestrator(nodeName: "Root \(label)") { input, context in
                    try await context.call(worker, input: input)
                }
            }

            async let first = flow.run(pipeline("A"), input: [:], makeSession: sessions)
            async let second = flow.run(pipeline("B"), input: [:], makeSession: sessions)
            _ = try await (first, second)

            let statuses = try await recorder.settled(runs: 2)
            let rendered = StatusRenderer.renderedByRun(statuses)
            try expectSequence(rendered, matches: Self.overlappingRunsGolden, named: "overlap")
            let runIDs = Set(statuses.compactMap { $0.runID })
            #expect(runIDs.count == 4, "each invocation has its own run id")
        }
    }
}

// MARK: - Goldens

extension RailtracksSwiftTestSuite.NodeStatusSequenceTests {
    static let agentCallingToolsGolden = """
        Assistant [Agent] queued node=node-1 parent=- run=run-1
        Assistant [Agent] executing node=node-1 parent=- run=run-1
        Lookup [Tool] queued node=node-2 parent=node-1 run=run-2
        Lookup [Tool] executing node=node-2 parent=node-1 run=run-2
        Lookup [Tool] completed node=node-2 parent=node-1 run=run-2
        Lookup [Tool] queued node=node-3 parent=node-1 run=run-3
        Lookup [Tool] executing node=node-3 parent=node-1 run=run-3
        Lookup [Tool] completed node=node-3 parent=node-1 run=run-3
        Summarize [Tool] queued node=node-4 parent=node-1 run=run-4
        Summarize [Tool] executing node=node-4 parent=node-1 run=run-4
        Summarize [Tool] completed node=node-4 parent=node-1 run=run-4
        Assistant [Agent] completed node=node-1 parent=- run=run-1
        """

    static let orchestratorRootGolden = """
        Planner [Function] queued node=node-1 parent=- run=run-1
        Planner [Function] executing node=node-1 parent=- run=run-1
        Researcher [Agent] queued node=node-2 parent=node-1 run=run-2
        Researcher [Agent] executing node=node-2 parent=node-1 run=run-2
        Lookup [Tool] queued node=node-3 parent=node-2 run=run-3
        Lookup [Tool] executing node=node-3 parent=node-2 run=run-3
        Lookup [Tool] completed node=node-3 parent=node-2 run=run-3
        Researcher [Agent] completed node=node-2 parent=node-1 run=run-2
        Formatter [Function] queued node=node-4 parent=node-1 run=run-4
        Formatter [Function] executing node=node-4 parent=node-1 run=run-4
        Formatter [Function] completed node=node-4 parent=node-1 run=run-4
        Planner [Function] completed node=node-1 parent=- run=run-1
        """

    /// `executing` is published even after a guardrail failed, so a node never finishes without
    /// having been seen to start.
    static let inputBlockGolden = """
        Blocked [Agent] queued node=node-1 parent=- run=run-1
        Blocked [Agent] executing node=node-1 parent=- run=run-1
        Blocked [Agent] failed(guardrailBlocked(guardrailName: "Refuse", stage: RailtracksSwift.RTSGuardrailStage.input, reason: "not allowed")) node=node-1 parent=- run=run-1
        """

    static let failurePropagatesGolden = """
        Pipeline [Function] queued node=node-1 parent=- run=run-1
        Pipeline [Function] executing node=node-1 parent=- run=run-1
        Calculator [Agent] queued node=node-2 parent=node-1 run=run-2
        Calculator [Agent] executing node=node-2 parent=node-1 run=run-2
        Divide [Tool] queued node=node-3 parent=node-2 run=run-3
        Divide [Tool] executing node=node-3 parent=node-2 run=run-3
        Divide [Tool] failed(StatusTestError()) node=node-3 parent=node-2 run=run-3
        Calculator [Agent] failed(StatusTestError()) node=node-2 parent=node-1 run=run-2
        Pipeline [Function] failed(StatusTestError()) node=node-1 parent=- run=run-1
        """

    static let endOnErrorStopGolden = """
        Pipeline [Function] queued node=node-1 parent=- run=run-1
        Pipeline [Function] executing node=node-1 parent=- run=run-1
        Calculator [Agent] queued node=node-2 parent=node-1 run=run-2
        Calculator [Agent] executing node=node-2 parent=node-1 run=run-2
        Divide [Tool] queued node=node-3 parent=node-2 run=run-3
        Divide [Tool] executing node=node-3 parent=node-2 run=run-3
        Divide [Tool] failed(StatusTestError()) node=node-3 parent=node-2 run=run-3
        Calculator [Agent] cancelled node=node-2 parent=node-1 run=run-2
        Pipeline [Function] cancelled node=node-1 parent=- run=run-1
        """

    /// For a cancel and a timeout alike. `Child` is created after the stop, so its body never runs,
    /// but it is still reported as executing before it is cancelled.
    static let stoppedRunGolden = """
        IgnoresStop [Function] queued node=node-1 parent=- run=run-1
        IgnoresStop [Function] executing node=node-1 parent=- run=run-1
        Child [Function] queued node=node-2 parent=node-1 run=run-2
        Child [Function] executing node=node-2 parent=node-1 run=run-2
        Child [Function] cancelled node=node-2 parent=node-1 run=run-2
        IgnoresStop [Function] cancelled node=node-1 parent=- run=run-1
        """

    static let overlappingRunsGolden = """
        Root A [Function] queued node=node-1 parent=- run=run-1
        Root A [Function] executing node=node-1 parent=- run=run-1
        Worker A [Function] queued node=node-2 parent=node-1 run=run-2
        Worker A [Function] executing node=node-2 parent=node-1 run=run-2
        Worker A [Function] completed node=node-2 parent=node-1 run=run-2
        Root A [Function] completed node=node-1 parent=- run=run-1

        Root B [Function] queued node=node-1 parent=- run=run-1
        Root B [Function] executing node=node-1 parent=- run=run-1
        Worker B [Function] queued node=node-2 parent=node-1 run=run-2
        Worker B [Function] executing node=node-2 parent=node-1 run=run-2
        Worker B [Function] completed node=node-2 parent=node-1 run=run-2
        Root B [Function] completed node=node-1 parent=- run=run-1
        """
}
