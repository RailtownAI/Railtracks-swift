//
//  MathWorkflow.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-07-03.
//

import Foundation
import RailtracksSwift

/// Function-node entry point for the Math demo. Orchestrates three math agents:
/// - Agents A → B run in sequence (A's answer feeds B's input).
/// - Agent C runs in parallel with the A → B chain.
struct MathWorkflow: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let agentA: RTSAgent
    let agentB: RTSAgent
    let agentC: RTSAgent
    let nodeName = "Math Workflow"

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        // --- Agent C: runs in PARALLEL with the A → B chain. ---
        async let cResult = context.call(
            agentC,
            prompt: "What is 50 - 17? Give the final answer as a single number."
        )

        // --- Agents A → B: SEQUENTIAL. A's result becomes B's input. ---
        let a = try await context.call(
            agentA,
            prompt: "What is 12 x 8? Give the final answer as a single number."
        )
        let b = try await context.call(
            agentB,
            prompt: "What is \(a) + 100? Give the final answer as a single number."
        )

        let c = try await cResult
        return ["result": .string("Sequential (A→B): \(b)\nParallel (C): \(c)")]
    }
}
