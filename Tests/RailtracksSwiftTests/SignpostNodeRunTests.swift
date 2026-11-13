//
//  SignpostNodeRunTests.swift
//  RailtracksSwiftTests
//

import Combine
import Testing
import Foundation
@testable import RailtracksSwift

/// Records the interval calls `RTSSignpostWriter` makes; point events are ignored.
private final class RecordingSignpostEmitter: RTSSignpostEmitting, @unchecked Sendable {
    struct Start: Equatable {
        let nodeID: UUID
        let parentNodeID: UUID?
        let nodeName: String
        let nodeType: RTSFlowNodeType
        let runID: RTSRunID
        let input: RTSInput
        let instructions: String?
    }

    struct End: Equatable {
        let nodeID: UUID
        let nodeType: RTSFlowNodeType
        let runID: RTSRunID
        let failed: Bool
    }

    private let lock = NSLock()
    private var _starts: [Start] = []
    private var _ends: [End] = []
    private var _graphNodeNames: [String] = []

    var starts: [Start] { lock.withLock { _starts } }
    var ends: [End] { lock.withLock { _ends } }
    /// The Flow Graph points' node names, so a test can tell whether points were emitted at all.
    var graphNodeNames: [String] { lock.withLock { _graphNodeNames } }

    func start(named name: String) -> Start? {
        starts.first { $0.nodeName == name }
    }

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
        let start = Start(
            nodeID: nodeID,
            parentNodeID: parentNodeID,
            nodeName: nodeName,
            nodeType: nodeType,
            runID: runID,
            input: input,
            instructions: instructions
        )
        lock.withLock { _starts.append(start) }
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
        let end = End(nodeID: nodeID, nodeType: nodeType, runID: runID, failed: error != nil)
        lock.withLock { _ends.append(end) }
    }

    func emitGraphNode(
        nodeID: String, parentID: String, sessionID: String, runID: String,
        nodeType: RTSFlowNodeType, parentType: RTSFlowNodeType?, error: Bool,
        parentError: Bool, cost: Double, model: String, parentName: String,
        name: String, startTime: TimeInterval
    ) {
        lock.withLock { _graphNodeNames.append(name) }
    }

    func emitTreeNode(
        nodeID: String, sessionID: String, runID: String, nodeType: RTSFlowNodeType,
        model: String, provider: String, cost: Double, latency: Double,
        inputTokens: Int, outputTokens: Int, error: Bool, ancestors: [String],
        name: String, startTime: TimeInterval,
        hasInputGuardrail: Bool, hasOutputGuardrail: Bool
    ) {}

    func emitIO(
        nodeID: String, sessionID: String, runID: String, messageID: String,
        source: String, direction: String, role: String, model: String,
        provider: String, cost: Double, latency: Double, inputTokens: Int,
        outputTokens: Int, displayRole: String, toolName: String, content: String,
        startTime: TimeInterval, hasInputGuardrail: Bool, hasOutputGuardrail: Bool
    ) {}
}

/// An invoker whose events reach a recording emitter through an `RTSSignpostWriter`, wired the way
/// `RTSFlow` wires them. Delivery is asynchronous, so read the recording after ``flush()``.
private struct SignpostedInvoker {
    let invoker: RTSNodeInvoker
    private let eventEmitter: RTSEventEmitter
    private let subscription: AnyCancellable

    init(_ recording: RecordingSignpostEmitter) {
        let sessionID = UUID()
        let eventEmitter = RTSEventEmitter(sessionID: sessionID.uuidString, isEnabled: true)
        let writer = RTSSignpostWriter(sessionID: sessionID, signpostEmitter: recording)
        self.subscription = writer.subscribe(to: eventEmitter.observedEventPublisher)
        self.eventEmitter = eventEmitter
        self.invoker = RTSNodeInvoker(eventEmitter: eventEmitter)
    }

    func flush() async {
        await eventEmitter.flushDelivery()
    }
}

/// Captures the system prompts an agent sets on its session.
private final class SystemPromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []

    var prompts: [String] { lock.withLock { _prompts } }

    func record(_ prompt: String) {
        lock.withLock { _prompts.append(prompt) }
    }
}

/// Minimal orchestrator whose body is supplied as a closure.
private struct StubOrchestrator: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName: String
    let body: @Sendable (RTSInput, RTSRunContext) async throws -> RTSOutput

    func name() -> String { nodeName }
    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        try await body(input, context)
    }
}

/// Tool that returns a fixed output, so no LLM is involved in running it.
private struct StubTool: RTSToolNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let toolName: String
    let toolDescription = "stub tool"
    let parameterSchema = RTSToolSchema(parameters: [])
    let callableRoutine = RTSClosure { _ in ["result": .string("tool")] }
}

extension RailtracksSwiftTestSuite {
    /// Every node call — not just agents — reaches `emitNodeStart`/`emitNodeEnd`, carrying its
    /// type and the invocation id of its caller, so the Instruments Node Runs lane can nest it.
    @Suite("Signpost Node Runs", .serialized)
    struct SignpostNodeRunTests {

        @Test("function → function reports both starts with type and parent id")
        func functionCallsFunction() async throws {
            let emitter = RecordingSignpostEmitter()
            let inner = StubOrchestrator(nodeName: "Inner") { _, _ in
                ["result": .string("inner")]
            }
            let outer = StubOrchestrator(nodeName: "Outer") { _, context in
                try await context.call(inner, input: [:])
            }
            let flow = RTSFlow(title: "SignpostFnToFn", signpostEmitter: emitter)
            _ = try await flow.run(outer, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            #expect(emitter.starts.count == 2)
            let root = try #require(emitter.start(named: "Outer"))
            let child = try #require(emitter.start(named: "Inner"))
            #expect(root.nodeType == .function)
            #expect(child.nodeType == .function)
            #expect(root.parentNodeID == nil)
            #expect(child.parentNodeID == root.nodeID)
            #expect(root.instructions == nil)
            #expect(child.instructions == nil)
            expectEveryStartEnded(emitter)
        }

        /// Signposts follow `emitsSignposts`, under `emitsEvents` as the master switch, and don't
        /// depend on `savesTrace`.
        @Test(
            "which flags give signposts",
            arguments: [
                (savesTrace: true, emitsEvents: true, emitsSignposts: true, expected: true),
                (savesTrace: false, emitsEvents: true, emitsSignposts: true, expected: true),
                (savesTrace: true, emitsEvents: true, emitsSignposts: false, expected: false),
                (savesTrace: true, emitsEvents: false, emitsSignposts: true, expected: false),
            ]
        )
        func signpostFlags(
            savesTrace: Bool,
            emitsEvents: Bool,
            emitsSignposts: Bool,
            expected: Bool
        ) async throws {
            let emitter = RecordingSignpostEmitter()
            let inner = StubOrchestrator(nodeName: "Inner") { _, _ in
                ["result": .string("inner")]
            }
            let outer = StubOrchestrator(nodeName: "Outer") { _, context in
                try await context.call(inner, input: [:])
            }
            let flow = RTSFlow(
                title: "SignpostFlags",
                savesTrace: savesTrace,
                emitsEvents: emitsEvents,
                emitsSignposts: emitsSignposts,
                signpostEmitter: emitter
            )
            _ = try await flow.run(outer, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            if expected {
                #expect(emitter.starts.map(\.nodeName) == ["Outer", "Inner"])
                #expect(emitter.graphNodeNames == ["Outer", "Inner"])
                expectEveryStartEnded(emitter)
            } else {
                #expect(emitter.starts.isEmpty)
                #expect(emitter.ends.isEmpty)
                #expect(emitter.graphNodeNames.isEmpty)
            }
        }

        @Test("a tool called from an agent reports the agent as its parent")
        func agentCallsTool() async throws {
            let emitter = RecordingSignpostEmitter()
            let signposted = SignpostedInvoker(emitter)
            let invoker = signposted.invoker
            let agent = RTSAgent(llmProvider: .openAI(modelIDString: "gpt-4o"), name: "Agent")
            let tool = StubTool(toolName: "Lookup")
            // Stands in for the LLM: the session's `run` makes one tool call through the
            // invoker, the way the Conduit/AppleAI tool bridges do, then answers.
            let session = RTSLLMSession(
                run: { _, _, _ in
                    _ = try await invoker.invokeTool(tool, input: [:], createdBy: agent)
                    return "done"
                },
                setSystemPrompt: { _, _ in },
                message: { [] },
                agentName: "Agent"
            )

            _ = try await invoker.invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: session
            )
            await signposted.flush()

            #expect(emitter.starts.count == 2)
            let agentStart = try #require(emitter.start(named: "Agent"))
            let toolStart = try #require(emitter.start(named: "Lookup"))
            #expect(agentStart.nodeType == .agent)
            #expect(toolStart.nodeType == .tool)
            #expect(agentStart.parentNodeID == nil)
            #expect(toolStart.parentNodeID == agentStart.nodeID)
            #expect(agentStart.instructions == nil)
            #expect(toolStart.instructions == nil)
            // The agent's start carries the input it ran with, which the emitter summarizes.
            #expect(agentStart.input == ["prompt": .string("hi")])
            #expect(RTSSignpostEmitter.inputSummary(agentStart.input, nodeType: .agent) == "hi")
            expectEveryStartEnded(emitter)
        }

        @Test("an agent's configured system message reaches the emitter as its instructions")
        func agentConfiguredInstructions() async throws {
            let emitter = RecordingSignpostEmitter()
            let systemPrompts = SystemPromptRecorder()
            let signposted = SignpostedInvoker(emitter)
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: "gpt-4o"),
                name: "Agent",
                systemMessage: "Be brief."
            )
            // Seeds the call input from `agent.inputs`, as `RTSFlow.run`, `RTSRunContext.call`
            // and the agent-tool bridges do; the invoker replaces the agent's inputs with it.
            var input = agent.inputs
            input["prompt"] = .string("hi")

            _ = try await signposted.invoker.invokeAgent(
                agent,
                input: input,
                session: stubSession(systemPrompts)
            )
            await signposted.flush()

            let start = try #require(emitter.start(named: "Agent"))
            #expect(start.instructions == "Be brief.")
            #expect(systemPrompts.prompts == ["Be brief."])
            expectEveryStartEnded(emitter)
        }

        @Test("a call-input system message overrides the configured one, and the emitter reports it")
        func callInputInstructionsWin() async throws {
            let emitter = RecordingSignpostEmitter()
            let systemPrompts = SystemPromptRecorder()
            let signposted = SignpostedInvoker(emitter)
            let agent = RTSAgent(
                llmProvider: .openAI(modelIDString: "gpt-4o"),
                name: "Agent",
                systemMessage: "Configured."
            )
            // Overlays the call's system message onto `agent.inputs`, as `RTSFlow.run` does when
            // passed `systemMessage:`.
            var input = agent.inputs
            input["prompt"] = .string("hi")
            input["systemMessage"] = .string("Per call.")

            _ = try await signposted.invoker.invokeAgent(
                agent,
                input: input,
                session: stubSession(systemPrompts)
            )
            await signposted.flush()

            let start = try #require(emitter.start(named: "Agent"))
            #expect(start.instructions == "Per call.")
            // The emitter reports exactly what the agent set on its session.
            #expect(systemPrompts.prompts == [start.instructions])
            expectEveryStartEnded(emitter)
        }

        @Test("an agent invoked without a system message reports nil instructions")
        func agentWithoutInstructions() async throws {
            let emitter = RecordingSignpostEmitter()
            let systemPrompts = SystemPromptRecorder()
            let signposted = SignpostedInvoker(emitter)
            let agent = RTSAgent(llmProvider: .openAI(modelIDString: "gpt-4o"), name: "Agent")

            _ = try await signposted.invoker.invokeAgent(
                agent,
                input: ["prompt": .string("hi")],
                session: stubSession(systemPrompts)
            )
            await signposted.flush()

            let start = try #require(emitter.start(named: "Agent"))
            #expect(start.instructions == nil)
            #expect(systemPrompts.prompts.isEmpty)
            expectEveryStartEnded(emitter)
        }

        /// A session that answers without an LLM and records every system prompt set on it.
        private func stubSession(_ systemPrompts: SystemPromptRecorder) -> RTSLLMSession {
            RTSLLMSession(
                run: { _, _, _ in "done" },
                setSystemPrompt: { prompt, _ in systemPrompts.record(prompt) },
                message: { [] },                agentName: "Agent"
            )
        }

        private func expectEveryStartEnded(_ emitter: RecordingSignpostEmitter) {
            let starts = emitter.starts
            let ends = emitter.ends
            #expect(ends.count == starts.count)
            for start in starts {
                let end = ends.first { $0.runID == start.runID }
                #expect(end?.nodeID == start.nodeID, "no matching end for \(start.nodeName)")
                #expect(end?.nodeType == start.nodeType)
                #expect(end?.failed == false)
            }
        }
    }
}
