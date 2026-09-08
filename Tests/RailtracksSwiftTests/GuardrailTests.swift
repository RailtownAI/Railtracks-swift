//
//  GuardrailTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-06-26.
//

import Testing
import Foundation
@testable import RailtracksSwift

private func str(_ v: RTSValue?) -> String? {
    if case let .string(s)? = v { return s }
    return nil
}

extension RailtracksSwiftTestSuite {
    @Suite("Guardrails")
    struct GuardrailTests {

        // MARK: - Input chain

        @Test("transform feeds the next guardrail; traces in order with correct phase")
        func inputChainTransform() async {
            let upper = RTSClosureInputGuardrail(name: "upper") { input in
                guard let p = str(input["prompt"]) else { return .allow() }
                return .transform(["prompt": .string(p.uppercased())], reason: "uppercased")
            }
            let observe = RTSClosureInputGuardrail(name: "observe") { input in
                // Must see the value transformed by `upper`.
                #expect(str(input["prompt"]) == "HELLO")
                return .allow("looks fine")
            }

            let outcome = await RTSGuardrailRunner.runInput(
                [upper, observe], input: ["prompt": .string("hello")]
            )
            let traces = outcome.traces

            #expect(outcome.error == nil)
            #expect(str(outcome.value["prompt"]) == "HELLO")
            #expect(traces.count == 2)
            #expect(traces[0].railName == "upper")
            #expect(traces[0].action == "transform")
            #expect(traces[0].phase == "llm_input")
            #expect(traces[1].action == "allow")
        }

        @Test("block short-circuits the chain and yields guardrailBlocked")
        func inputBlock() async {
            let blocker = RTSClosureInputGuardrail(name: "blocker") { _ in .block("nope") }
            let never = RTSClosureInputGuardrail(name: "never") { _ in
                Issue.record("guardrail after a block must not run")
                return .allow()
            }

            let outcome = await RTSGuardrailRunner.runInput(
                [blocker, never], input: ["prompt": .string("x")]
            )
            let traces = outcome.traces
            let error = outcome.error

            #expect(traces.count == 1)
            #expect(traces[0].action == "block")
            #expect(traces[0].reason == "nope")

            guard case let .guardrailBlocked(name, stage, reason, _)? = error as? RTSError else {
                Issue.record("expected RTSError.guardrailBlocked, got \(String(describing: error))")
                return
            }
            #expect(name == "blocker")
            #expect(stage == .input)
            #expect(reason == "nope")
        }

        @Test("a throwing guardrail records an error trace and propagates (strict)")
        func inputThrows() async {
            struct Boom: Error {}
            let crash = RTSClosureInputGuardrail(name: "crash") { _ in throw Boom() }

            let outcome = await RTSGuardrailRunner.runInput([crash], input: [:])
            let traces = outcome.traces
            let error = outcome.error

            #expect(traces.count == 1)
            #expect(traces[0].action == "error")
            #expect(traces[0].reason == "Guardrail raised exception")
            #expect(traces[0].metadata?["exception_type"] != nil)
            #expect(error is Boom)
        }

        // MARK: - Output chain

        @Test("output block yields guardrailBlocked at the output stage")
        func outputBlock() async {
            let blocker = RTSClosureOutputGuardrail(name: "out-blocker") { _ in .block("unsafe output") }

            let outcome = await RTSGuardrailRunner.runOutput(
                [blocker], output: ["result": .string("secret")]
            )
            let traces = outcome.traces
            let error = outcome.error

            #expect(traces.count == 1)
            #expect(traces[0].action == "block")
            #expect(traces[0].phase == "llm_output")

            guard case let .guardrailBlocked(_, stage, _, _)? = error as? RTSError else {
                Issue.record("expected RTSError.guardrailBlocked")
                return
            }
            #expect(stage == .output)
        }

        // MARK: - Trace serialization

        @Test("trace serializes to the JSON format field names")
        func traceJSONFieldNames() throws {
            let trace = RTSGuardrailTrace(
                railName: "PIIGuard",
                stage: .input,
                action: .transform,
                reason: "redacted",
                metadata: ["count": .number(2)]
            )
            let data = try JSONEncoder().encode(trace)
            let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(obj["rail_name"] as? String == "PIIGuard")
            #expect(obj["phase"] as? String == "llm_input")
            #expect(obj["action"] as? String == "transform")
            #expect(obj["reason"] as? String == "redacted")
            let meta = obj["meta"] as? [String: Any]
            #expect(meta?["count"] as? Double == 2)
        }

        @Test("guardrail name defaults to the conforming type name")
        func defaultName() {
            struct MyGuard: RTSAgentInputGuardrail {
                func check(_ input: RTSInput) async throws -> RTSInputGuardrailResult { .allow() }
            }
            #expect(MyGuard().name == "MyGuard")
        }
    }
}
