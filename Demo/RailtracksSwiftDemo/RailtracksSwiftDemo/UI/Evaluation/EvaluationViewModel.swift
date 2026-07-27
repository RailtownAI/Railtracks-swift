//
//  EvaluationViewModel.swift
//  RailtracksSwiftDemo
//

import Foundation
import Combine
import RailtracksSwift
import Logging

/// Drives the evaluation demo: discover trace JSONs written by the other demos, group them by the
/// flow that produced them, then run the selected evaluators and persist a report.
@Observable
class EvaluationViewModel {

    /// One selectable group of traces, all produced by the same flow (same filename prefix).
    struct TraceGroup: Identifiable {
        let id: String            // the flow title
        let flowTitle: String
        let label: String         // display label ("<button> - <flow>" when known)
        let files: [URL]
        var isSelected: Bool
    }

    var groups: [TraceGroup] = []
    var includeToolUse = true
    var includeLLMInference = true
    var includeJudge = false
    var saveJudgeTraces = false
    var hasAnthropicKey = false
    var isRunning = false
    var progress = ""
    var failureCount = 0
    var summary = ""

    private var progressCancellable: AnyCancellable?

    /// Display-only map: flow title → the ContentView demo button it came from. Lets a demo that emits
    /// more than one flow (e.g. "Math Error" + "Throwing Workflow") show where each trace originated.
    /// Grouping is driven by files on disk, so an unknown flow still appears (labeled by its raw title).
    private static let demoButtonByFlowTitle: [String: String] = [
        "Simple prompt flow": "Simple",
        "Math Workflow": "Math",
        "Math Assistant (AppleAI)": "Math(AppleAI)",
        "Math Verify flow": "Verified Math",
        "Math Error": "Math Error",
        "Throwing Workflow": "Math Error",
        "Extract Job Description": "Output Schema",
        "Safe Support Assistant": "Guardrails",
    ]

    func onAppear() {
        hasAnthropicKey = KeychainHelper.readAnthropicKey().isNotNilNorEmpty
        if !hasAnthropicKey {
            includeJudge = false
        }
        scanTraces()
    }

    /// Discover trace files and group them by the flow title embedded in the filename
    /// (`<flowTitle>_<sessionID>.json`). The session UUID contains no underscore, so the last
    /// underscore always separates the title from the id.
    func scanTraces() {
        let directory = RailtracksSwift.flowGraphOutputDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        var filesByTitle: [String: [URL]] = [:]
        for url in files {
            let name = url.lastPathComponent
            guard url.pathExtension == "json", !name.hasPrefix(".") else {
                continue
            }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let separator = stem.lastIndex(of: "_") else {
                continue
            }
            let flowTitle = String(stem[stem.startIndex..<separator])
            filesByTitle[flowTitle, default: []].append(url)
        }

        // Preserve the user's current checkbox selections across a rescan.
        let previousSelection = Dictionary(
            groups.map { ($0.id, $0.isSelected) },
            uniquingKeysWith: { first, _ in first }
        )
        // Only surface known demo flows — ignore everything else in the directory (debug message
        // dumps, ad-hoc logs, traces from removed/renamed demos), which would otherwise clutter the
        // list and can't be meaningfully evaluated here.
        groups = filesByTitle.keys
            .filter { Self.demoButtonByFlowTitle[$0] != nil }
            .sorted()
            .map { flowTitle in
                TraceGroup(
                    id: flowTitle,
                    flowTitle: flowTitle,
                    label: Self.label(forFlowTitle: flowTitle),
                    files: filesByTitle[flowTitle] ?? [],
                    isSelected: previousSelection[flowTitle] ?? true
                )
            }
    }

    private static func label(forFlowTitle flowTitle: String) -> String {
        // Always prefix with the originating demo button when known — even when it repeats the flow
        // title (e.g. "Math Error - Math Error"). Clarity about where a flow came from beats avoiding
        // the repetition, especially for a view that emits multiple flows.
        guard let button = demoButtonByFlowTitle[flowTitle] else {
            return flowTitle
        }
        return "\(button) - \(flowTitle)"
    }

    func toggleGroup(_ id: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            return
        }
        groups[index].isSelected.toggle()
    }

    var canRun: Bool {
        let anyFiles = groups.contains { $0.isSelected }
        let anyEvaluator = includeToolUse || includeLLMInference || (includeJudge && hasAnthropicKey)
        return anyFiles && anyEvaluator && !isRunning
    }

    func run() {
        let selectedFiles = groups.filter { $0.isSelected }.flatMap { $0.files }
        guard !selectedFiles.isEmpty else {
            summary = "No traces selected."
            return
        }

        var evaluators: [any RTSEvaluator] = []
        if includeToolUse {
            evaluators.append(RTSToolUseEvaluator())
        }
        if includeLLMInference {
            evaluators.append(RTSLLMInferenceEvaluator())
        }
        if includeJudge, let apiKey = KeychainHelper.readAnthropicKey() {
            let gateway = RTSLLMGateway(apiKeys: [.anthropic: apiKey])
            let metric = RTSCategoricalMetric(
                name: "Helpfulness",
                categories: ["Very Helpful", "Helpful", "Not Helpful"],
                description: "How helpful was the agent's response in addressing the user's request?"
            )
            evaluators.append(
                RTSJudgeEvaluator(
                    provider: .anthropic(modelIDString: RTSAnthropicModelID.claudeSonnet46.modelIDString),
                    gateway: gateway,
                    metrics: [metric],
                    savesTrace: saveJudgeTraces
                )
            )
        }
        guard !evaluators.isEmpty else {
            summary = "No evaluators selected."
            return
        }

        isRunning = true
        summary = "Evaluating…"
        progress = ""
        failureCount = 0

        // The manager ingests + evaluates and owns the (serialized, throttled) progress feed. Subscribe
        // on main so UI updates are safe. Evaluation name is left nil so the visualizer titles rows by
        // agent name (its documented fallback `evaluation_name ?? agents[0].agent_name`).
        let manager = RTSEvaluationManager()
        progressCancellable = manager.progressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.applyProgress(event)
            }

        Task { [weak self] in
            defer { self?.isRunning = false }
            let started = DispatchTime.now()
            let reports = await manager.run(fromFiles: selectedFiles, evaluators: evaluators)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                - started.uptimeNanoseconds) / 1_000_000_000
            self?.summarize(reports: reports, elapsed: elapsed)
        }
    }

    /// Reflect a live progress/failure event into the UI. Already delivered on main (see `.receive(on:)`).
    private func applyProgress(_ event: RTSEvaluationEvent) {
        switch event {
        case .ingesting(let filesCompleted, let totalFiles, let runsProcessed):
            progress = "Ingesting \(filesCompleted)/\(totalFiles) files · \(runsProcessed) runs"
        case .evaluating(let completed, let total):
            progress = "Evaluating \(completed)/\(total)"
        case .ingestFailed(let file, let message):
            failureCount += 1
            Log.debug("⚠️ ingest failure #\(failureCount) [\(file)]: \(message)")
        case .evaluationFailed(let evaluator, let agent, let message):
            failureCount += 1
            Log.debug("⚠️ eval failure #\(failureCount) [\(evaluator)/\(agent ?? "?")]: \(message)")
        case .finished(let reportCount):
            progress = "Finished · \(reportCount) report(s)"
        }
    }

    private func summarize(reports: [RTSEvaluationReport], elapsed: TimeInterval) {
        let dataCount = reports.reduce(0) { sum, report in
            sum + report.agents.reduce(0) { $0 + $1.agentNodeIds.count }
        }
        var lines: [String] = []
        lines.append(String(
            format: "Evaluated %d data point(s) → %d report(s) in %.2fs.",
            dataCount, reports.count, elapsed
        ))
        if failureCount > 0 {
            lines.append("⚠️ \(failureCount) non-blocking failure(s) — see logs")
        }
        lines.append("Output: \(RailtracksSwift.evaluationOutputDirectory.path)")
        for report in reports {
            let agentName = report.agents.first?.agentName ?? "unknown agent"
            let evaluatorNames = report.evaluatorResults
                .map { $0.evaluatorName }
                .joined(separator: ", ")
            lines.append("• \(agentName): \(evaluatorNames)")
            // Surface any categorical (judge) distributions inline.
            for evaluatorResult in report.evaluatorResults {
                for node in evaluatorResult.aggregateResults.nodes.values {
                    guard case .categoricalAggregate(let aggregate) = node else {
                        continue
                    }
                    let distribution = aggregate.counts
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: ", ")
                    lines.append("    \(aggregate.name): \(distribution)")
                }
            }
        }
        summary = lines.joined(separator: "\n")
    }
}
