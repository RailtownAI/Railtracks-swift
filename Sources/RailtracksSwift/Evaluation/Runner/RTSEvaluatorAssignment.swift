//
//  RTSEvaluatorAssignment.swift
//  RailtracksSwift
//

import Foundation

/// Assigns one evaluator to a scope of agents, for `RTSEvaluation.evaluate(data:assignments:)` — so
/// different evaluators can run over different agents. See docs/evaluator-agent-targeting.md.
///
/// Targeting is by agent *name* (matching `RTSAgentDataPoint.agentName`), and:
/// - `agents == nil` runs the evaluator on **every** agent present in the data.
/// - Per agent, the evaluator set is the **union** across all matching assignments, so overlapping
///   scopes compose.
/// - The set is **deduplicated by `evaluator.identifier`**, so the same evaluator never runs twice on
///   one agent.
/// - An agent that ends up with **no** evaluators produces **no** report.
///
/// The assignment carries the runnable evaluator instance (not just an id): `evaluate` invokes
/// `evaluator.run(_:context:)`, which needs the instance — an id string isn't runnable.
public struct RTSEvaluatorAssignment: Sendable {
    public let evaluator: any RTSEvaluator
    public let agents: [String]?

    public init(evaluator: any RTSEvaluator, agents: [String]? = nil) {
        self.evaluator = evaluator
        self.agents = agents
    }
}
