//
//  SignpostLagProbeTests.swift
//  RailtracksSwiftTests
//
//  THROWAWAY (#70 step 1, not to be committed). Runs the scenarios in
//  docs/signposts-from-events.md and prints what `RTSSignpostLagProbe` measured. No assertions.
//

import Combine
import Foundation
import Testing
@testable import RailtracksSwift

@Suite(.serialized)
struct SignpostLagProbeTests {
    private static let workerCount = 16

    @Test("sequential: an agent calling three tools, 30 runs")
    func sequential() async throws {
        let flow = RTSFlow(title: "Lag Sequential")
        let lookup = echoTool("Lookup")
        let agent = RTSAgent(llmProvider: toolCallingProvider, name: "Assistant", tools: [lookup])
        let script = ScriptedReply(
            toolCalls: [
                ScriptedToolCall(tool: lookup, input: ["query": .string("alpha")]),
                ScriptedToolCall(tool: lookup, input: ["query": .string("beta")]),
                ScriptedToolCall(tool: lookup, input: ["query": .string("gamma")]),
            ]
        )
        for _ in 0..<30 {
            _ = try await flow.run(
                agent: agent,
                prompt: "Find them",
                makeSession: scriptedSessions(["Assistant": script])
            )
        }
        await report(flow, title: "sequential")
    }

    @Test("concurrent: 16 agents at once, each calling three 2 ms tools, 10 runs")
    func concurrent() async throws {
        let flow = RTSFlow(title: "Lag Concurrent")
        try await runFanOut(on: flow, runs: 10)
        await report(flow, title: "concurrent")
    }

    @Test("concurrent, savesTrace false: no collector or event log")
    func concurrentWithoutTrace() async throws {
        let flow = RTSFlow(title: "Lag Concurrent No Trace", savesTrace: false)
        try await runFanOut(on: flow, runs: 10)
        await report(flow, title: "concurrent, savesTrace false")
    }

    @Test("concurrent, with an app sink on eventPublisher that takes 1 ms per event")
    func slowAppSink() async throws {
        let flow = RTSFlow(title: "Lag Slow Sink")
        let subscription = flow.eventPublisher.sink { _ in
            Thread.sleep(forTimeInterval: 0.001)
        }
        try await runFanOut(on: flow, runs: 3)
        await report(flow, title: "concurrent, slow app sink")
        subscription.cancel()
    }

    @Test("slow app sink, emitsSignposts false: probe only")
    func slowAppSinkWithoutSignposts() async throws {
        let flow = RTSFlow(title: "Lag Slow Sink No Signposts", emitsSignposts: false)
        let subscription = flow.eventPublisher.sink { _ in
            Thread.sleep(forTimeInterval: 0.001)
        }
        try await runFanOut(on: flow, runs: 3)
        await report(flow, title: "concurrent, slow app sink, no signposts")
        subscription.cancel()
    }

    // MARK: - Helpers

    private func runFanOut(on flow: RTSFlow, runs: Int) async throws {
        let tool = ScriptedTool("Work") { input in
            try await Task.sleep(for: .milliseconds(2))
            return ["result": .string("worked \(input["query"]?.textForScript ?? "")")]
        }
        var scripts: [String: ScriptedReply] = [:]
        var agents: [RTSAgent] = []
        for index in 0..<Self.workerCount {
            let name = "Worker \(index)"
            agents.append(RTSAgent(llmProvider: toolCallingProvider, name: name, tools: [tool]))
            scripts[name] = ScriptedReply(
                toolCalls: (0..<3).map { call in
                    ScriptedToolCall(tool: tool, input: ["query": .string("\(index)-\(call)")])
                }
            )
        }
        let workers = agents
        let fanOut = ScriptedOrchestrator(nodeName: "Fan Out") { _, context in
            try await withThrowingTaskGroup(of: String.self) { group in
                for agent in workers {
                    group.addTask {
                        try await context.call(agent, prompt: "work")
                    }
                }
                var results: [String] = []
                for try await result in group {
                    results.append(result)
                }
                return ["result": .string(results.joined(separator: ","))]
            }
        }
        for _ in 0..<runs {
            _ = try await flow.run(fanOut, input: [:], makeSession: scriptedSessions(scripts))
        }
    }

    private func report(_ flow: RTSFlow, title: String) async {
        await flow.flushEvents()
        print(RTSSignpostLagProbe.summary(of: flow.lagProbe.samples, title: "ALL \(title)"))
    }
}
