//
//  TraceGoldenTests.swift
//  RailtracksSwiftTests
//
//  Pins the whole flow-graph trace a run writes — every key, every record, every step — so a
//  change to how the trace is collected can prove the file is unchanged. Each test runs a real
//  `RTSFlow`, with agents on scripted sessions, normalizes what it wrote and compares it with a
//  golden. See docs/trace-from-events.md.
//

import Foundation
import Synchronization
import Testing
@testable import RailtracksSwift

// MARK: - Scripted model

/// One tool call a scripted model makes before it replies.
private struct ScriptedToolCall: Sendable {
    let tool: any RTSToolNode
    let input: RTSInput
}

/// What a scripted model does in one agent invocation: call its tools in order, then reply.
private struct ScriptedReply: Sendable {
    var toolCalls: [ScriptedToolCall] = []
    var reply = "done"
    var providerName: String? = "AppleAI"
    var model: String? = "apple-on-device"
    /// When a tool call throws, wait to be cancelled rather than rethrowing, as a provider does
    /// while the run's stop reaches it. Makes an end-on-error stop deterministic.
    var waitsForStopAfterToolFailure = false
}

/// A session that plays a ``ScriptedReply`` and records the messages a real provider would: the
/// system prompt, the user prompt, an assistant message per tool call with its tool result, and
/// the final reply, each stamped with the invocation's `runID`.
private final class ScriptedSession: Sendable {
    private let script: ScriptedReply
    private let invoker: RTSNodeInvoker
    private let agent: any RTSAgentNode
    private let log = Mutex<[RTSMessage]>([])
    private let subject = BufferedPassthroughSubject<[RTSMessage]>()

    private init(
        script: ScriptedReply,
        invoker: RTSNodeInvoker,
        agent: any RTSAgentNode
    ) {
        self.script = script
        self.invoker = invoker
        self.agent = agent
    }

    static func make(
        script: ScriptedReply,
        invoker: RTSNodeInvoker,
        agent: any RTSAgentNode
    ) -> RTSLLMSession {
        let scripted = ScriptedSession(script: script, invoker: invoker, agent: agent)
        return RTSLLMSession(
            run: { prompt, _, runID in
                try await scripted.run(prompt: prompt, runID: runID)
            },
            setSystemPrompt: { systemPrompt, runID in
                scripted.publish([scripted.message(.system, systemPrompt, runID: runID)])
            },
            message: {
                scripted.log.withLock { $0 }
            },
            messageSubject: scripted.subject,
            agentName: agent.agentName
        )
    }

    private func run(prompt: String, runID: UUID?) async throws -> String {
        var produced = [message(.user, prompt, runID: runID)]
        // Published however the call ends, as `RTSLLMSession` publishes what accumulated when a
        // send throws.
        defer {
            publish(produced)
        }
        for (index, call) in script.toolCalls.enumerated() {
            let callID = "call_\(index)"
            produced.append(assistantToolCall(call, callID: callID, runID: runID))
            let output: RTSOutput
            do {
                output = try await invoker.invokeTool(
                    call.tool,
                    input: call.input,
                    createdBy: agent
                )
            } catch {
                guard script.waitsForStopAfterToolFailure else {
                    throw error
                }
                try await Task.sleep(for: .seconds(30))
                throw error
            }
            produced.append(toolResult(output, call: call, callID: callID, runID: runID))
        }
        produced.append(
            message(.assistant, script.reply, runID: runID, metadata: modelMetadata(toolCalls: nil))
        )
        return script.reply
    }

    private func publish(_ messages: [RTSMessage]) {
        log.withLock { $0.append(contentsOf: messages) }
        subject.send(messages)
    }

    private func message(
        _ role: RTSMessage.Role,
        _ text: String,
        runID: UUID?,
        metadata: RTSMessageMetadata? = nil
    ) -> RTSMessage {
        RTSMessage(
            id: UUID(),
            role: role,
            content: .text(text),
            timestamp: Date(),
            metadata: metadata,
            runID: runID
        )
    }

    private func assistantToolCall(
        _ call: ScriptedToolCall,
        callID: String,
        runID: UUID?
    ) -> RTSMessage {
        let arguments = RTSGeneratedContent(kind: .structure(call.input.mapValues { value in
            RTSGeneratedContent(kind: .string(value.textForScript))
        }))
        let toolCall = RTSToolCall(id: callID, toolName: call.tool.toolName, arguments: arguments)
        return message(.assistant, "", runID: runID, metadata: modelMetadata(toolCalls: [toolCall]))
    }

    private func toolResult(
        _ output: RTSOutput,
        call: ScriptedToolCall,
        callID: String,
        runID: UUID?
    ) -> RTSMessage {
        let metadata = RTSMessageMetadata(
            tokenCount: nil,
            inputTokenCount: nil,
            generationTime: nil,
            model: nil,
            providerName: nil,
            tokensPerSecond: nil,
            providerExtra: nil,
            custom: ["tool_call_id": callID, "tool_name": call.tool.toolName],
            toolCalls: nil
        )
        let text = output["result"]?.textForScript ?? ""
        return message(.tool, text, runID: runID, metadata: metadata)
    }

    private func modelMetadata(toolCalls: [RTSToolCall]?) -> RTSMessageMetadata {
        RTSMessageMetadata(
            tokenCount: 7,
            inputTokenCount: 11,
            generationTime: 0.5,
            model: script.model,
            providerName: script.providerName,
            tokensPerSecond: nil,
            providerExtra: nil,
            custom: nil,
            toolCalls: toolCalls
        )
    }
}

private extension RTSValue {
    /// A string value's text, so scripted messages never depend on dictionary ordering.
    var textForScript: String {
        if case .string(let text) = self {
            return text
        }
        return ""
    }
}

/// Builds every agent's session from `scripts`, keyed by agent name.
private func scriptedSessions(_ scripts: [String: ScriptedReply]) -> RTSFlow.SessionFactory {
    { invoker, agent in
        ScriptedSession.make(
            script: scripts[agent.agentName] ?? ScriptedReply(),
            invoker: invoker,
            agent: agent
        )
    }
}

// MARK: - Nodes

/// A tool whose body is supplied as a closure.
private struct ScriptedTool: RTSToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName: String
    let toolDescription = "scripted tool"
    let parameterSchema = RTSToolSchema(parameters: [])
    let callableRoutine: RTSClosure

    init(
        _ toolName: String,
        body: @escaping @Sendable (RTSInput) async throws -> RTSOutput
    ) {
        self.toolName = toolName
        self.callableRoutine = RTSClosure(closure: body)
    }
}

/// An orchestrator whose body is supplied as a closure.
private struct ScriptedOrchestrator: RTSOrchestratorNode {
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

/// A tool that echoes its `query` input as its result.
private func echoTool(_ name: String) -> ScriptedTool {
    ScriptedTool(name) { input in
        ["result": .string("\(name): \(input["query"]?.textForScript ?? "")")]
    }
}

// MARK: - Normalization

/// Makes a written trace comparable across runs.
///
/// - `nodes` and `edges` are sorted by `stamp.step`, which is deterministic for a sequential flow.
/// - Every UUID becomes `<id-N>`, numbered by first appearance, so references stay linked: an
///   edge's `source` and `target` to node ids, `run_id` to the root edge.
/// - Wall-clock times become `<time>` and measured ones `<duration>`, once they are known to be
///   numbers. Step numbers are kept.
/// - A call site's line number becomes `<line>`, so editing a source file does not move a golden.
private struct TraceNormalizer {
    private static let timeKeys: Set<String> = ["time", "start_time", "end_time"]
    private static let durationKeys: Set<String> = ["total_time"]

    private var placeholders: [String: String] = [:]

    static func normalized(_ data: Data) throws -> String {
        let root = try JSONSerialization.jsonObject(with: data)
        var normalizer = TraceNormalizer()
        let normalized = normalizer.normalize(sortingRecords(root), key: nil)
        let output = try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: output, as: UTF8.self)
    }

    private static func sortingRecords(_ value: Any) -> Any {
        guard var object = value as? [String: Any] else {
            return value
        }
        if let runs = object["runs"] as? [[String: Any]] {
            object["runs"] = runs.map { run in
                var sorted = run
                for key in ["nodes", "edges"] {
                    if let records = run[key] as? [[String: Any]] {
                        sorted[key] = records.sorted { step(of: $0) < step(of: $1) }
                    }
                }
                return sorted
            }
        }
        return object
    }

    private static func step(of record: [String: Any]) -> Int {
        let stamp = record["stamp"] as? [String: Any]
        return (stamp?["step"] as? Int) ?? Int.max
    }

    private mutating func normalize(_ value: Any, key: String?) -> Any {
        if let key, value is NSNumber {
            if TraceNormalizer.timeKeys.contains(key) {
                return "<time>"
            }
            if TraceNormalizer.durationKeys.contains(key) {
                return "<duration>"
            }
        }
        switch value {
        case let object as [String: Any]:
            var normalized: [String: Any] = [:]
            for childKey in object.keys.sorted() {
                normalized[childKey] = normalize(object[childKey] as Any, key: childKey)
            }
            return normalized
        case let array as [Any]:
            return array.map { normalize($0, key: nil) }
        case let text as String:
            return normalize(text)
        default:
            return value
        }
    }

    private mutating func normalize(_ text: String) -> String {
        if UUID(uuidString: text) != nil {
            if let placeholder = placeholders[text] {
                return placeholder
            }
            let placeholder = "<id-\(placeholders.count + 1)>"
            placeholders[text] = placeholder
            return placeholder
        }
        return text.replacing(/:\d+(?= in )/, with: ":<line>")
    }
}

// MARK: - Running

/// The trace the flow's latest run wrote. `run` returns only once it is written, and the URL
/// publisher replays its latest value, so this reads the file of the run that just returned.
private func writtenTrace(of flow: RTSFlow) async throws -> Data {
    for await result in flow.outputFileURLPublisher.values {
        switch result {
        case .success(let url):
            return try Data(contentsOf: url)
        case .failure(let error):
            throw error
        }
    }
    struct NoTraceWritten: Error {
    }
    throw NoTraceWritten()
}

/// Compares a trace with its golden. On a mismatch the actual trace is saved next to the other
/// test output, so a deliberate change can be reviewed and pasted in.
private func expectTrace(
    _ data: Data,
    matches golden: String,
    named name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let normalized = try TraceNormalizer.normalized(data)
    guard normalized != golden else {
        return
    }
    let saved = FileManager.default.temporaryDirectory
        .appendingPathComponent("trace-golden-\(name).json")
    try normalized.write(to: saved, atomically: true, encoding: .utf8)
    Issue.record(
        "trace \(name) differs from its golden; actual saved to \(saved.path)",
        sourceLocation: sourceLocation
    )
}

private let toolCallingProvider = RTSLLMProvider.appleAI

// MARK: - Signposts

/// Records the collector's point signposts (graph node, tree node, IO) as one line each.
///
/// Times become `<time>` / `<duration>` as they are recorded. Ids are left for ``lines`` to
/// replace, since a node's name is only known from its graph signpost. Tree and IO signposts are
/// emitted from detached tasks, so their order varies and the lines are sorted.
private final class RecordingPointSignposts: RTSSignpostEmitting, Sendable {
    private struct GraphNode {
        let nodeID: String
        let name: String
        let parentID: String
        let runID: String
    }

    private let records = Mutex<[String]>([])
    private let graphNodes = Mutex<[GraphNode]>([])
    private let treeNodeCount = Mutex(0)

    func emitNodeStart(
        nodeID: UUID,
        parentNodeID: UUID?,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        input: RTSInput,
        instructions: String?,
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    ) {
    }

    func emitNodeEnd(
        nodeID: UUID,
        nodeName: String,
        nodeType: RTSFlowNodeType,
        sessionID: UUID,
        parentName: String,
        runID: RTSRunID,
        output: RTSOutput?,
        error: Error?
    ) {
    }

    func emitGraphNode(
        nodeID: String,
        parentID: String,
        sessionID: String,
        runID: String,
        nodeType: RTSFlowNodeType,
        parentType: RTSFlowNodeType?,
        error: Bool,
        parentError: Bool,
        cost: Double,
        model: String,
        parentName: String,
        name: String,
        startTime: TimeInterval
    ) {
        graphNodes.withLock { nodes in
            nodes.append(GraphNode(nodeID: nodeID, name: name, parentID: parentID, runID: runID))
        }
        record(
            "graph \(name) node=\(nodeID) parent=\(parentName) parentID=\(parentID)"
                + " type=\(nodeType.rawValue) parentType=\(parentType?.rawValue ?? "nil")"
                + " error=\(error) parentError=\(parentError) cost=\(cost) model=\(model)"
                + " session=\(sessionID) run=\(runID) start=\(Self.time(startTime))"
        )
    }

    func emitTreeNode(
        nodeID: String,
        sessionID: String,
        runID: String,
        nodeType: RTSFlowNodeType,
        model: String,
        provider: String,
        cost: Double,
        latency: Double,
        inputTokens: Int,
        outputTokens: Int,
        error: Bool,
        ancestors: [String],
        name: String,
        startTime: TimeInterval,
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    ) {
        treeNodeCount.withLock { $0 += 1 }
        let duration = latency >= 0 ? "<duration>" : "negative"
        record(
            "tree \(name) node=\(nodeID) type=\(nodeType.rawValue) model=\(model)"
                + " provider=\(provider) cost=\(cost) latency=\(duration)"
                + " tokens=\(inputTokens)/\(outputTokens) error=\(error)"
                + " ancestors=\(ancestors.joined(separator: ">"))"
                + " guards=\(hasInputGuardrail)/\(hasOutputGuardrail)"
                + " session=\(sessionID) run=\(runID) start=\(Self.time(startTime))"
        )
    }

    func emitIO(
        nodeID: String,
        sessionID: String,
        runID: String,
        messageID: String,
        source: String,
        direction: String,
        role: String,
        model: String,
        provider: String,
        cost: Double,
        latency: Double,
        inputTokens: Int,
        outputTokens: Int,
        displayRole: String,
        toolName: String,
        content: String,
        startTime: TimeInterval,
        hasInputGuardrail: Bool,
        hasOutputGuardrail: Bool
    ) {
        record(
            "io \(toolName) \(displayRole) node=\(nodeID) message=\(messageID) source=\(source)"
                + " direction=\(direction) role=\(role) model=\(model) provider=\(provider)"
                + " cost=\(cost) latency=\(latency) tokens=\(inputTokens)/\(outputTokens)"
                + " content=\(content) guards=\(hasInputGuardrail)/\(hasOutputGuardrail)"
                + " session=\(sessionID) run=\(runID) start=\(Self.time(startTime))"
        )
    }

    /// Waits for the detached tree and IO signposts: until every graph node has its tree node,
    /// and then until nothing more arrives for a moment.
    func settled() async throws {
        for _ in 0..<100 {
            let graphCount = graphNodes.withLock { $0.count }
            if graphCount > 0, treeNodeCount.withLock({ $0 }) == graphCount {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        var count = records.withLock { $0.count }
        while true {
            try await Task.sleep(for: .milliseconds(100))
            let latest = records.withLock { $0.count }
            if latest == count {
                return
            }
            count = latest
        }
    }

    /// The sorted lines, with node ids replaced by `<node:Name>`, the session id by `<session>`,
    /// the root's run id by `<run>`, and other ids (messages, edges) by `<id>`.
    func lines(sessionID: UUID) -> [String] {
        let nodes = graphNodes.withLock { $0 }
        let names = Dictionary(
            nodes.map { ($0.nodeID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let rootRunID = nodes.first { $0.parentID.isEmpty }?.runID
        let uuidPattern = /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/
        return records.withLock { $0 }
            .map { line in
                line.replacing(uuidPattern) { match in
                    let identifier = String(match.output)
                    if identifier == sessionID.uuidString {
                        return "<session>"
                    }
                    if identifier == rootRunID {
                        return "<run>"
                    }
                    if let name = names[identifier] {
                        return "<node:\(name)>"
                    }
                    return "<id>"
                }
            }
            .sorted()
    }

    private func record(_ line: String) {
        records.withLock { $0.append(line) }
    }

    private static func time(_ startTime: TimeInterval) -> String {
        startTime > 0 ? "<time>" : "zero"
    }
}

extension RailtracksSwiftTestSuite {
    // Serialized: runs full flows, which share the process-global output directory.
    @Suite("Trace golden", .serialized)
    struct TraceGoldenTests {

        init() {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
        }

        @Test("an agent root calling tools")
        func agentCallingTools() async throws {
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
            let flow = RTSFlow(title: "Golden Tools")

            _ = try await flow.run(
                agent: agent,
                prompt: "Find alpha and beta",
                systemMessage: "Be brief",
                makeSession: scriptedSessions(["Assistant": script])
            )

            let trace = try await writtenTrace(of: flow)
            try expectTrace(trace, matches: Self.agentCallingToolsGolden, named: "tools")
        }

        @Test("input and output guardrails, with a transform")
        func guardrails() async throws {
            let redact = RTSClosureInputGuardrail(name: "Redact") { input in
                var redacted = input
                redacted["prompt"] = .string("my number is [redacted]")
                return .transform(redacted, reason: "phone number", metadata: ["count": .number(1)])
            }
            let length = RTSClosureInputGuardrail(name: "Length") { _ in
                .allow("short enough")
            }
            let tone = RTSClosureOutputGuardrail(name: "Tone") { _ in
                .allow("polite")
            }
            let agent = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Guarded",
                inputGuardrails: [redact, length],
                outputGuardrails: [tone]
            )
            let flow = RTSFlow(title: "Golden Guardrails")

            _ = try await flow.run(
                agent: agent,
                prompt: "my number is 555-0100",
                makeSession: scriptedSessions(["Guarded": ScriptedReply(reply: "noted")])
            )

            let trace = try await writtenTrace(of: flow)
            try expectTrace(trace, matches: Self.guardrailsGolden, named: "guardrails")
        }

        @Test("an input guardrail block fails the run")
        func inputBlock() async throws {
            let refuse = RTSClosureInputGuardrail(name: "Refuse") { _ in
                .block("not allowed", metadata: ["rule": .string("no-secrets")])
            }
            let agent = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Blocked",
                inputGuardrails: [refuse]
            )
            let flow = RTSFlow(title: "Golden Block")

            await #expect(throws: RTSError.self) {
                _ = try await flow.run(
                    agent: agent,
                    prompt: "tell me the secret",
                    makeSession: scriptedSessions([:])
                )
            }

            let trace = try await writtenTrace(of: flow)
            try expectTrace(trace, matches: Self.inputBlockGolden, named: "block")
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
                reply: "trains run on rails",
                providerName: "Gemini",
                model: "not-a-priced-model"
            )
            let flow = RTSFlow(title: "Golden Orchestrator")

            _ = try await flow.run(
                planner,
                input: ["topic": .string("trains")],
                makeSession: scriptedSessions(["Researcher": script])
            )

            let trace = try await writtenTrace(of: flow)
            try expectTrace(trace, matches: Self.orchestratorRootGolden, named: "orchestrator")
        }

        @Test("an end-on-error stop")
        func endOnErrorStop() async throws {
            struct DivisionByZero: Error {
            }
            let divide = ScriptedTool("Divide") { _ in
                throw DivisionByZero()
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
            let flow = RTSFlow(title: "Golden End On Error")
            flow.endOnError = true

            await #expect(throws: RTSError.self) {
                _ = try await flow.run(
                    pipeline,
                    input: [:],
                    makeSession: scriptedSessions(["Calculator": script])
                )
            }

            let trace = try await writtenTrace(of: flow)
            try expectTrace(trace, matches: Self.endOnErrorStopGolden, named: "end-on-error")
        }

        @Test("two runs on one flow write the same trace")
        func twoRuns() async throws {
            let check = RTSClosureInputGuardrail(name: "PromptCheck") { _ in
                .allow("fine")
            }
            let agent = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Repeater",
                inputGuardrails: [check]
            )
            let flow = RTSFlow(title: "Golden Two Runs")
            let sessions = scriptedSessions(["Repeater": ScriptedReply(reply: "again")])

            _ = try await flow.run(agent: agent, prompt: "once more", makeSession: sessions)
            let first = try await writtenTrace(of: flow)
            _ = try await flow.run(agent: agent, prompt: "once more", makeSession: sessions)
            let second = try await writtenTrace(of: flow)

            try expectTrace(first, matches: Self.twoRunsGolden, named: "two-runs-first")
            try expectTrace(second, matches: Self.twoRunsGolden, named: "two-runs-second")
        }

        @Test("savesTrace: false writes no trace")
        func noTraceWhenNotSaving() async throws {
            let agent = RTSAgent(llmProvider: toolCallingProvider, name: "Quiet")
            let flow = RTSFlow(title: "Golden Quiet", savesTrace: false)

            let sessions = scriptedSessions([:])

            _ = try await flow.run(agent: agent, prompt: "hello", makeSession: sessions)

            let url = RailtracksSwift.flowGraphOutputDirectory
                .appendingPathComponent("Golden Quiet_\(flow.id.uuidString)")
                .appendingPathExtension("json")
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        /// The collector's Instruments point signposts: a graph node per invocation, a tree node per
        /// finished node, and an IO row per message and per edge input and output.
        @Test("the collector's signposts")
        func collectorSignposts() async throws {
            let lookup = echoTool("Lookup")
            let check = RTSClosureInputGuardrail(name: "Check") { _ in
                .allow("fine")
            }
            let researcher = RTSAgent(
                llmProvider: toolCallingProvider,
                name: "Researcher",
                tools: [lookup],
                inputGuardrails: [check]
            )
            let planner = ScriptedOrchestrator(nodeName: "Planner") { _, context in
                let draft = try await context.call(researcher, prompt: "Research trains")
                return ["summary": .string(draft)]
            }
            let script = ScriptedReply(
                toolCalls: [ScriptedToolCall(tool: lookup, input: ["query": .string("trains")])],
                reply: "trains run on rails"
            )
            let signposts = RecordingPointSignposts()
            let flow = RTSFlow(title: "Golden Signposts", signpostEmitter: signposts)

            _ = try await flow.run(
                planner,
                input: ["topic": .string("trains")],
                makeSession: scriptedSessions(["Researcher": script])
            )
            try await signposts.settled()

            let lines = signposts.lines(sessionID: flow.id).joined(separator: "\n")
            guard lines != Self.signpostsGolden else {
                return
            }
            let saved = FileManager.default.temporaryDirectory
                .appendingPathComponent("trace-golden-signposts.txt")
            try lines.write(to: saved, atomically: true, encoding: .utf8)
            Issue.record("signposts differ from their golden; actual saved to \(saved.path)")
        }

        /// A failed session build exits before the root exists. The next run on the flow still
        /// writes its own, complete trace.
        @Test("a failed session build doesn't disturb the flow's next run")
        func failedSessionBuild() async throws {
            struct NoSession: Error {
            }
            let agent = RTSAgent(llmProvider: toolCallingProvider, name: "Retried")
            let flow = RTSFlow(title: "Golden Failed Session")
            let failing: RTSFlow.SessionFactory = { _, _ in
                throw NoSession()
            }

            await #expect(throws: NoSession.self) {
                _ = try await flow.run(agent: agent, prompt: "hello", makeSession: failing)
            }
            _ = try await flow.run(agent: agent, prompt: "hello", makeSession: scriptedSessions([:]))

            let trace = try await writtenTrace(of: flow)
            let graph = try JSONDecoder().decode(RTSFlowGraph.self, from: trace)
            let run = try #require(graph.runs.first)
            #expect(run.nodes.map { $0.name } == ["Retried"])
            #expect(run.steps.map { $0.identifier } == [
                "START CREATED Retried",
                "Finished executing Retried",
            ])
        }

        /// The trace is built from the observability events, so a flow that emits none writes none,
        /// whatever `savesTrace` says.
        @Test("emitsEvents: false writes no trace")
        func noTraceWithoutEvents() async throws {
            let agent = RTSAgent(llmProvider: toolCallingProvider, name: "Silent")
            let flow = RTSFlow(title: "Golden Silent", savesTrace: true, emitsEvents: false)
            let sessions = scriptedSessions([:])

            _ = try await flow.run(agent: agent, prompt: "hello", makeSession: sessions)

            let url = RailtracksSwift.flowGraphOutputDirectory
                .appendingPathComponent("Golden Silent_\(flow.id.uuidString)")
                .appendingPathExtension("json")
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        /// Two runs in flight on one flow share its emitter. Each run's trace holds only its own
        /// nodes. They share a file name, so the file holds whichever finished last.
        @Test("overlapping runs on one flow don't mix their traces")
        func overlappingRuns() async throws {
            let flow = RTSFlow(title: "Golden Overlap")
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

            let trace = try await writtenTrace(of: flow)
            let graph = try JSONDecoder().decode(RTSFlowGraph.self, from: trace)
            let run = try #require(graph.runs.first)
            let names = Set(run.nodes.map { $0.name })
            #expect(names == ["Root A", "Worker A"] || names == ["Root B", "Worker B"])
            #expect(run.edges.count == 2)
            #expect(run.steps.count == 4)
        }
    }
}
