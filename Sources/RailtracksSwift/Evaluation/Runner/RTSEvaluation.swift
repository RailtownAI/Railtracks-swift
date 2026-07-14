//
//  RTSEvaluation.swift
//  RailtracksSwift
//

import Foundation

/// Stage 2 of evaluation: run evaluators over already-ingested agent data points and produce one
/// report per agent. Data points are grouped by agent name; each agent is evaluated concurrently
/// (Level-A parallelism). Reports are written to `RailtracksSwift.evaluationOutputDirectory`.
public enum RTSEvaluation {

    /// Evaluate `data` with `evaluators`, producing one `RTSEvaluationReport` per agent.
    ///
    /// - Parameters:
    ///   - data: ingested agent data points (see `RTSEvaluationIngest`).
    ///   - evaluators: the evaluators to apply to every selected agent.
    ///   - agents: optional filter — only agents whose name is in this list are evaluated;
    ///     when nil, all agents present in `data` are evaluated.
    ///   - name: optional human-readable evaluation name recorded on each report.
    ///   - persist: when true (default), each report is written to `evaluationOutputDirectory`.
    public static func evaluate(
        data: [RTSAgentDataPoint],
        evaluators: [any RTSEvaluator],
        agents: [String]? = nil,
        name: String? = nil,
        persist: Bool = true
    ) async -> [RTSEvaluationReport] {
        var pointsByAgent: [String: [RTSAgentDataPoint]] = [:]
        for point in data {
            pointsByAgent[point.agentName, default: []].append(point)
        }

        let selected: [String]
        if let agents {
            selected = agents.filter { pointsByAgent[$0] != nil }
        } else {
            selected = Array(pointsByAgent.keys)
        }

        // Create the output directory once up front; a failure here disables persistence for the
        // whole run (logged once) rather than having every task retry and re-log the same error.
        let shouldPersist = persist && prepareOutputDirectory()

        // Level A: evaluate agents concurrently (independent reports, no shared state). Each report
        // is persisted as soon as it finishes, overlapping its disk write with the other agents'
        // still-running evaluation. Concurrent writes are safe — each targets a distinct file.
        let reports = await withTaskGroup(
            of: RTSEvaluationReport.self,
            returning: [RTSEvaluationReport].self
        ) { group in
            for agentName in selected {
                let points = pointsByAgent[agentName] ?? []
                group.addTask {
                    let report = await buildReport(
                        agentName: agentName,
                        points: points,
                        evaluators: evaluators,
                        name: name
                    )
                    if shouldPersist {
                        persistOne(report)
                    }
                    return report
                }
            }
            var collected: [RTSEvaluationReport] = []
            for await report in group {
                collected.append(report)
            }
            return collected
        }

        return reports
    }

    // MARK: - Per-agent report

    private static func buildReport(
        agentName: String,
        points: [RTSAgentDataPoint],
        evaluators: [any RTSEvaluator],
        name: String?
    ) async -> RTSEvaluationReport {
        let createdAt = RTSISODate(Date())

        var evaluatorResults: [RTSEvaluatorResult] = []
        var metricsMap: [String: RTSMetric] = [:]
        for evaluator in evaluators {
            do {
                let output = try await evaluator.run(points)
                evaluatorResults.append(output.result)
                for metric in output.metrics {
                    metricsMap[metric.identifier] = metric
                }
            } catch {
                // A failing evaluator is logged and skipped; evaluation continues.
                log.error("🧪 evaluator \(evaluator.name) failed for agent \(agentName): \(error)")
            }
        }

        let agentNodeIds = points.map {
            RTSAgentNodeRef(sessionId: $0.sessionID.uuidString, agentNodeId: $0.id.uuidString)
        }

        return RTSEvaluationReport(
            evaluationId: UUID().uuidString,
            createdAt: createdAt,
            completedAt: RTSISODate(Date()),
            evaluationName: name,
            agents: [RTSReportAgent(agentName: agentName, agentNodeIds: agentNodeIds)],
            metricsMap: metricsMap,
            evaluatorResults: evaluatorResults
        )
    }

    // MARK: - Persistence

    /// Create the evaluation output directory once, before any report is written. Returns whether
    /// it exists / was created; a failure disables persistence for the whole run (logged once).
    private static func prepareOutputDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: RailtracksSwift.evaluationOutputDirectory,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            log.error("🧪 could not create evaluation output directory: \(error)")
            return false
        }
    }

    /// Write a single report to `evaluationOutputDirectory/<evaluation_id>.json`. Best-effort: a
    /// failure is logged, never thrown, so a write error can't fail the evaluation. Safe to call
    /// concurrently — each report writes a distinct file with its own encoder.
    private static func persistOne(_ report: RTSEvaluationReport) {
        let encoder = JSONEncoder()
        #if DEBUG
        encoder.outputFormatting = .prettyPrinted
        #endif
        let url = RailtracksSwift.evaluationOutputDirectory
            .appendingPathComponent(report.evaluationId)
            .appendingPathExtension("json")
        do {
            try encoder.encode(report).write(to: url)
            log.debug("🧪 wrote evaluation report: \(url.lastPathComponent)")
        } catch {
            log.error("🧪 could not write evaluation report \(report.evaluationId): \(error)")
        }
    }
}
