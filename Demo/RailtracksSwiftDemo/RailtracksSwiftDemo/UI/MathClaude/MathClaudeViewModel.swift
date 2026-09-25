//
//  MathClaudeViewModel.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-09-24.
//
//  A member of the RailtracksSwiftDemoOS27 target only — excluded from the main Demo target —
//  because Swift refuses to import ClaudeForFoundationModels (minimum OS 27) into the main Demo's
//  15.6 / 18.6 target, `@available` gating notwithstanding.
//

import Foundation
import Combine
import FoundationModels
import ClaudeForFoundationModels
import RailtracksSwift
import RailtracksSwiftUI
import Logging

/// Runs the AppleAI math demo's tools on Claude Sonnet 4.6 through either of the library's two
/// paths to Claude, and sums each run's tokens and cost from its trace so they can be compared:
///
/// - **FoundationModels** — `.foundationModel` wrapping `ClaudeLanguageModel`, through Apple's
///   `LanguageModelSession`.
/// - **Conduit** — `.anthropic`, the library's default Claude path.
///
/// Same prompt, system message, tools and model on both, so any difference is the path's.
@available(macOS 27, iOS 27, *)
@Observable
class MathClaudeViewModel {
    enum Path: String, CaseIterable, Identifiable {
        case foundationModels = "FoundationModels"
        case conduit = "Conduit"

        var id: Self {
            self
        }
    }

    /// One run's usage, summed from its flow-graph trace.
    struct RunSummary {
        let roundTrips: Int
        let inputTokens: Int
        let outputTokens: Int
        /// `nil` when no round trip was priced.
        let cost: Double?
        let traceStatus: String
    }

    let prompt = MathToolsPrompt.prompt
    var promptResult: String = ""
    var isRunning = false
    var isShowingKeyPrompt = false
    /// The latest run per path, so both can be on screen together.
    var summaries: [Path: RunSummary] = [:]
    /// Every run on this screen stacks into one call-tree history, one root per run.
    @MainActor let nodeTree = RTSNodeTreeViewModel()

    /// The path a run was asked for while the key prompt is up, resumed once a key is saved.
    private var pendingPath: Path?

    /// The pricing key for both paths — the same model id the Conduit case uses, so both price
    /// against the same entry.
    private static let modelID = RTSAnthropicModelID.claudeSonnet46.modelIDString

    func run(via path: Path) {
        guard let apiKey = KeychainHelper.readAnthropicKey() else {
            pendingPath = path
            isShowingKeyPrompt = true
            return
        }
        isRunning = true
        promptResult = "waiting..."
        Task { [weak self] in
            defer {
                self?.isRunning = false
            }
            await self?.execute(path, apiKey: apiKey)
        }
    }

    func resumeAfterKeySaved() {
        isShowingKeyPrompt = false
        guard let path = pendingPath else {
            return
        }
        pendingPath = nil
        run(via: path)
    }

    private func execute(_ path: Path, apiKey: String) async {
        let flow = RTSFlow(title: "Math Assistant (Claude via \(path.rawValue))")
        nodeTree.attach(to: flow)
        let agent = RTSAgent(
            llmProvider: Self.provider(for: path, apiKey: apiKey),
            name: "Claude Math Assistant Agent",
            tools: [
                AdditionToolApple(),
                SubtractionToolApple(),
                MultiplicationToolApple(),
                DivisionToolApple(),
            ],
            systemMessage: MathToolsPrompt.systemMessage
        )
        let gateway = Self.gateway(for: path, apiKey: apiKey)
        Log.debug("starting Claude math run via \(path.rawValue)")
        do {
            promptResult = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
        } catch {
            promptResult = "Run failed: \(error)"
        }
        summaries[path] = await Self.summary(of: flow)
        Log.debug("finished Claude math run via \(path.rawValue)")
    }

    private static func provider(for path: Path, apiKey: String) -> RTSLLMProvider {
        switch path {
        case .foundationModels:
            let claude = ClaudeLanguageModel(name: .sonnet4_6, auth: .apiKey(apiKey))
            return .foundationModel(RTSFoundationLanguageModel(claude, kind: .anthropic, modelID: modelID))
        case .conduit:
            return .anthropic(modelIDString: modelID)
        }
    }

    /// The FoundationModels path takes no gateway key: the model carries its own auth.
    private static func gateway(for path: Path, apiKey: String) -> RTSLLMGateway {
        switch path {
        case .foundationModels:
            return RTSLLMGateway(apiKeys: [:])
        case .conduit:
            return RTSLLMGateway(apiKeys: [.anthropic: apiKey])
        }
    }

    // MARK: - Trace summary

    /// Sums the run's `llm_details` — one entry per round trip — across every node in its trace.
    private static func summary(of flow: RTSFlow) async -> RunSummary {
        switch await traceResult(of: flow) {
        case .success(let url):
            do {
                let graph = try JSONDecoder().decode(RTSFlowGraph.self, from: Data(contentsOf: url))
                let roundTrips = graph.runs
                    .flatMap(\.nodes)
                    .flatMap { $0.details.internals.llmDetails ?? [] }
                let costs = roundTrips.compactMap(\.totalCost)
                return RunSummary(
                    roundTrips: roundTrips.count,
                    inputTokens: roundTrips.map(\.inputTokens).reduce(0, +),
                    outputTokens: roundTrips.map(\.outputTokens).reduce(0, +),
                    cost: costs.isEmpty ? nil : costs.reduce(0, +),
                    traceStatus: "Trace: \(url.lastPathComponent)"
                )
            } catch {
                return emptySummary(traceStatus: "Trace unreadable: \(error)")
            }
        case .failure(let error):
            return emptySummary(traceStatus: "Trace write failed: \(error)")
        case nil:
            return emptySummary(traceStatus: "No trace written")
        }
    }

    private static func emptySummary(traceStatus: String) -> RunSummary {
        RunSummary(roundTrips: 0, inputTokens: 0, outputTokens: 0, cost: nil, traceStatus: traceStatus)
    }

    /// The trace this run wrote. `run` returns only after the trace is written, and the publisher
    /// replays its latest result, so this resolves at once; the timeout covers a run that failed
    /// before producing any trace, which would otherwise wait forever.
    private static func traceResult(of flow: RTSFlow) async -> Result<URL, Error>? {
        await withTaskGroup(of: Result<URL, Error>?.self) { group in
            group.addTask {
                for await result in flow.outputFileURLPublisher.values {
                    return result
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
