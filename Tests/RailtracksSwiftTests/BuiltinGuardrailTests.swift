//
//  BuiltinGuardrailTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-06-29.
//

import Testing
import Foundation
@testable import RailtracksSwift

private func str(_ v: RTSValue?) -> String? {
    if case let .string(s)? = v { return s }
    return nil
}

extension RailtracksSwiftTestSuite {
    @Suite("Builtin Guardrails")
    struct BuiltinGuardrailTests {

        // MARK: - Length

        @Test("length guard blocks over the limit, allows under")
        func length() async throws {
            let guard5 = RTSLengthInputGuardrail(maxCharacters: 5)

            if case let .blocked(reason, meta) = try await guard5.check(["prompt": .string("toolong")]) {
                #expect(reason.contains("exceeds"))
                #expect(meta?["max_chars"] != nil)
            } else {
                Issue.record("expected block")
            }

            if case .allowed = try await guard5.check(["prompt": .string("hi")]) {
                // ok
            } else {
                Issue.record("expected allow")
            }
        }

        // MARK: - BlockText

        @Test("block-text guard blocks on regex match, allows otherwise")
        func blockText() async throws {
            let rail = try RTSBlockTextInputGuardrail(pattern: #"(?i)\bpassword\b"#)

            if case let .blocked(reason, _) = try await rail.check(["prompt": .string("my PASSWORD is x")]) {
                #expect(reason == "Input blocked: prohibited content detected.")
            } else {
                Issue.record("expected block")
            }

            if case .allowed = try await rail.check(["prompt": .string("hello world")]) {
                // ok
            } else {
                Issue.record("expected allow")
            }
        }

        @Test("block-text guard init throws on invalid regex")
        func blockTextInvalidPattern() {
            #expect(throws: (any Error).self) {
                _ = try RTSBlockTextInputGuardrail(pattern: "[unterminated")
            }
        }

        // MARK: - PII

        @Test("pii guard redacts email and reports metadata")
        func piiEmail() async throws {
            let rail = try RTSPIIRedactInputGuardrail()
            let result = try await rail.check(["prompt": .string("contact me at alice@example.com please")])

            guard case let .transformed(newInput, reason, meta) = result else {
                Issue.record("expected transform")
                return
            }
            #expect(str(newInput["prompt"]) == "contact me at [EMAIL_ADDRESS] please")
            #expect(reason.contains("Redacted"))
            #expect(meta?["redacted_entities"] != nil)
        }

        @Test("pii guard allows when no PII present")
        func piiClean() async throws {
            let rail = try RTSPIIRedactInputGuardrail()
            if case .allowed = try await rail.check(["prompt": .string("just a normal question")]) {
                // ok
            } else {
                Issue.record("expected allow")
            }
        }

        @Test("pii guard drops credit-card numbers failing the Luhn check")
        func piiLuhn() async throws {
            let rail = try RTSPIIRedactInputGuardrail(config: .init(entities: [.creditCard]))
            // 4111 1111 1111 1111 is a valid Luhn test number; mutate last digit to fail.
            let valid = try await rail.check(["prompt": .string("card 4111 1111 1111 1111")])
            let invalid = try await rail.check(["prompt": .string("card 4111 1111 1111 1112")])

            if case .transformed = valid {} else { Issue.record("valid card should redact") }
            if case .allowed = invalid {} else { Issue.record("invalid Luhn should not redact") }
        }

        @Test("pii guard supports custom patterns and throws on bad custom regex")
        func piiCustom() async throws {
            let rail = try RTSPIIRedactInputGuardrail(
                config: .init(entities: [], customPatterns: [.init(name: "EMPLOYEE_ID", regex: #"EMP-\d{4}"#)])
            )
            let result = try await rail.check(["prompt": .string("see EMP-1234 for details")])
            if case let .transformed(newInput, _, _) = result {
                #expect(str(newInput["prompt"]) == "see [EMPLOYEE_ID] for details")
            } else {
                Issue.record("expected transform")
            }

            #expect(throws: (any Error).self) {
                _ = try RTSPIIRedactInputGuardrail(
                    config: .init(customPatterns: [.init(name: "BAD", regex: "[")])
                )
            }
        }
    }
}
