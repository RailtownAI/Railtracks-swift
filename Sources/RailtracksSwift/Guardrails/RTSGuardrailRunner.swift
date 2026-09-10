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
        input: RTSInput,
        eventContext: RTSGuardrailEventContext? = nil
    ) async -> RTSGuardrailInputOutcome {
        var current = input
        var traces: [RTSGuardrailTrace] = []
        for (index, rail) in guardrails.enumerated() {
            let railEvents = eventContext?.beginRail(stage: .input, index: index, name: rail.name)
            // The chain-level pair brackets the guard-specific one, as Python's chain wraps the
            // middleware it runs.
            railEvents?.emitChainInvocation(value: current)
            // Carries `current`, not the original input: each rail sees the previous rail's
            // transformed value, and the event should record what this rail actually saw.
            railEvents?.emitInputInvocation(current)
            let result: RTSInputGuardrailResult
            do {
                result = try await rail.check(current)
            } catch {
                log.debug("🛡️ [\(rail.name)] llm_input → error: \(error)")
                traces.append(
                    .error(railName: rail.name, stage: .input, error: error)
                )
                railEvents?.emitInputFailure(error)
                railEvents?.emitChainFailure(error)
                return RTSGuardrailInputOutcome(value: current, traces: traces, error: error)
            }
            // Emitted for every verdict including a block — see `RTSGuardrailRailEvents`.
            // The decision is built inside the optional chain, so it costs nothing when
            // there is no event context.
            railEvents?.emitInputResponse(
                unchanged: current,
                decision: RTSGuardrailDecision(result)
            )
            switch result {
            case .allowed(let reason, let metadata):
                log.debug("🛡️ [\(rail.name)] llm_input → allow: \(reason)")
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .input,
                        action: .allow,
                        reason: reason,
                        metadata: metadata
                    )
                )
                railEvents?.emitChainResponse(value: current)
            case .transformed(let newInput, let reason, let metadata):
                log.debug("🛡️ [\(rail.name)] llm_input → transform: \(reason)")
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
                railEvents?.emitChainResponse(value: newInput)
            case .blocked(let reason, let metadata):
                log.debug("🛡️ [\(rail.name)] llm_input → block: \(reason)")
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .input,
                        action: .block,
                        reason: reason,
                        metadata: metadata
                    )
                )
                let blocked = RTSError.guardrailBlocked(
                    guardrailName: rail.name,
                    stage: .input,
                    reason: reason
                )
                // A block stops the call, so at the chain level it is a failure — the same
                // shape Python produces when `_raise_if_blocked` raises through the chain.
                railEvents?.emitChainFailure(blocked)
                return RTSGuardrailInputOutcome(
                    value: current,
                    traces: traces,
                    error: blocked
                )
            }
        }
        return RTSGuardrailInputOutcome(value: current, traces: traces, error: nil)
    }

    static func runOutput(
        _ guardrails: [any RTSAgentOutputGuardrail],
        output: RTSOutput,
        eventContext: RTSGuardrailEventContext? = nil
    ) async -> RTSGuardrailOutputOutcome {
        var current = output
        var traces: [RTSGuardrailTrace] = []
        for (index, rail) in guardrails.enumerated() {
            let railEvents = eventContext?.beginRail(stage: .output, index: index, name: rail.name)
            railEvents?.emitChainInvocation(value: current)
            railEvents?.emitOutputInvocation(current)
            let result: RTSOutputGuardrailResult
            do {
                result = try await rail.check(current)
            } catch {
                log.debug("🛡️ [\(rail.name)] llm_output → error: \(error)")
                traces.append(
                    .error(railName: rail.name, stage: .output, error: error)
                )
                railEvents?.emitOutputFailure(error)
                railEvents?.emitChainFailure(error)
                return RTSGuardrailOutputOutcome(value: current, traces: traces, error: error)
            }
            railEvents?.emitOutputResponse(
                unchanged: current,
                decision: RTSGuardrailDecision(result)
            )
            switch result {
            case .allowed(let reason, let metadata):
                log.debug("🛡️ [\(rail.name)] llm_output → allow: \(reason)")
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .output,
                        action: .allow,
                        reason: reason,
                        metadata: metadata
                    )
                )
                railEvents?.emitChainResponse(value: current)
            case .transformed(let newOutput, let reason, let metadata):
                log.debug("🛡️ [\(rail.name)] llm_output → transform: \(reason)")
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
                railEvents?.emitChainResponse(value: newOutput)
            case .blocked(let reason, let metadata):
                log.debug("🛡️ [\(rail.name)] llm_output → block: \(reason)")
                traces.append(
                    RTSGuardrailTrace(
                        railName: rail.name,
                        stage: .output,
                        action: .block,
                        reason: reason,
                        metadata: metadata
                    )
                )
                let blocked = RTSError.guardrailBlocked(
                    guardrailName: rail.name,
                    stage: .output,
                    reason: reason
                )
                railEvents?.emitChainFailure(blocked)
                return RTSGuardrailOutputOutcome(
                    value: current,
                    traces: traces,
                    error: blocked
                )
            }
        }
        return RTSGuardrailOutputOutcome(value: current, traces: traces, error: nil)
    }
}
