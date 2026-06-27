//
//  RTSGuardrailRunner.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-06-26.
//

import Foundation

/// Executes an agent's guardrail chain and produces the trace records.
///
/// Never throws. Returns the (possibly transformed) value, the collected traces
/// in execution order, and an optional terminal `error`:
/// - `RTSError.guardrailBlocked` when a guardrail returned `.blocked`, or
/// - the propagated exception when a guardrail's `check` threw (strict mode).
///
/// The caller (the node invoker) attaches the traces to the agent's node and
/// re-throws `error` so the run fails.
enum RTSGuardrailRunner {
    static func runInput(
        _ guardrails: [any RTSAgentInputGuardrail],
        input: RTSInput
    ) async -> (value: RTSInput, traces: [RTSGuardrailTrace], error: Error?) {
        var current = input
        var traces: [RTSGuardrailTrace] = []
        for rail in guardrails {
            let result: RTSInputGuardrailResult
            do {
                result = try await rail.check(current)
            } catch {
                traces.append(
                    .error(railName: rail.name, stage: .input, error: error)
                )
                return (current, traces, error)
            }
            switch result {
            case .allowed(let reason, let metadata):
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .input,
                        action: .allow,
                        reason: reason,
                        metadata: metadata
                    )
                )
            case .transformed(let newInput, let reason, let metadata):
                current = newInput
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .input,
                        action: .transform,
                        reason: reason,
                        metadata: metadata
                    )
                )
            case .blocked(let reason, let metadata):
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .input,
                        action: .block,
                        reason: reason,
                        metadata: metadata
                    )
                )
                return (
                    current,
                    traces,
                    RTSError.guardrailBlocked(
                        guardrailName: rail.name,
                        stage: .input,
                        reason: reason
                    )
                )
            }
        }
        return (current, traces, nil)
    }

    static func runOutput(
        _ guardrails: [any RTSAgentOutputGuardrail],
        output: RTSOutput
    ) async -> (value: RTSOutput, traces: [RTSGuardrailTrace], error: Error?) {
        var current = output
        var traces: [RTSGuardrailTrace] = []
        for rail in guardrails {
            let result: RTSOutputGuardrailResult
            do {
                result = try await rail.check(current)
            } catch {
                traces.append(
                    .error(railName: rail.name, stage: .output, error: error)
                )
                return (current, traces, error)
            }
            switch result {
            case .allowed(let reason, let metadata):
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .output,
                        action: .allow,
                        reason: reason,
                        metadata: metadata
                    )
                )
            case .transformed(let newOutput, let reason, let metadata):
                current = newOutput
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .output,
                        action: .transform,
                        reason: reason,
                        metadata: metadata
                    )
                )
            case .blocked(let reason, let metadata):
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .output,
                        action: .block,
                        reason: reason,
                        metadata: metadata
                    )
                )
                return (
                    current,
                    traces,
                    RTSError.guardrailBlocked(
                        guardrailName: rail.name,
                        stage: .output,
                        reason: reason
                    )
                )
            }
        }
        return (current, traces, nil)
    }
}
