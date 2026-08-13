//
//  AppleAITaskLocalProbeTests.swift
//  RailtracksSwiftTests
//
//  THROWAWAY PROBE (pre-implementation verification).
//
//  The per-invocation node-id fix propagates a parent's invocation id to its children via a
//  `@TaskLocal`, read inside each child's `invokeCore` as the edge `source`. That relies on the
//  tool-calling framework preserving task-locals across the tool call. Conduit is confirmed
//  (parallel tools run in a `TaskGroup`, which inherits task-locals; no `Task.detached`). Apple's
//  `LanguageModelSession.respond` is a closed framework — this probe answers the only open question:
//  *does `respond` call `Tool.call` on a task that still sees a task-local bound around it?*
//
//  It touches NONE of the fix code — it binds its own task-local, lets `respond` drive a real
//  tool call, and checks what the tool observed. Structure mirrors the real path exactly: the
//  binding is placed OUTSIDE `respond` (as `invokeCore` will place it around `execute`), and the
//  tool reads it from INSIDE the framework's tool invocation.
//
//  Runs only on macOS 26 with the on-device model available; otherwise it no-ops (prints a skip).
//  See docs/duplicate-node-id.md.
//

import Testing
import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// The task-local we probe — stands in for `RTSNodeInvoker.currentInvocationID`.
@available(macOS 26, iOS 26, *)
enum TaskLocalProbe {
    @TaskLocal static var marker: UUID?
}

/// Thread-safe box for what the tool observed (`call` is async and may hop executors).
final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWasCalled = false
    private var storedObserved: UUID?

    func record(_ value: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        storedWasCalled = true
        storedObserved = value
    }

    var wasCalled: Bool {
        lock.withLock { storedWasCalled }
    }

    var observed: UUID? {
        lock.withLock { storedObserved }
    }
}

/// A minimal FoundationModels tool that records whether the caller's task-local was visible.
@available(macOS 26, iOS 26, *)
struct TaskLocalProbeTool: Tool {
    typealias Output = String

    @Generable
    struct Arguments: Encodable {
        @Guide(description: "Any short string, e.g. 'go'.")
        var input: String
    }

    let recorder: ProbeRecorder

    var name: String {
        "task_local_probe"
    }

    var description: String {
        "A diagnostic tool. Call it exactly once with input 'go'."
    }

    func call(arguments: Arguments) async throws -> String {
        // The crux: is the task-local bound around `respond` still visible inside the tool call?
        recorder.record(TaskLocalProbe.marker)
        return "ok"
    }
}

extension RailtracksSwiftTestSuite {
    @Suite("AppleAI task-local propagation probe")
    struct AppleAITaskLocalProbeTests {

        @Test("LanguageModelSession.respond preserves @TaskLocal into Tool.call")
        func respondPreservesTaskLocal() async throws {
            guard #available(macOS 26, iOS 26, *) else {
                print("⏭️  AppleAI probe skipped — requires macOS 26 / iOS 26.")
                return
            }

            let availability = SystemLanguageModel.default.availability
            guard case .available = availability else {
                print("⏭️  AppleAI probe skipped — on-device model unavailable: \(availability). "
                    + "Run this from the Demo app (Xcode) where the model is reachable, if `swift test` can't see it.")
                return
            }

            let recorder = ProbeRecorder()
            let expected = UUID()
            let tool = TaskLocalProbeTool(recorder: recorder)

            try await TaskLocalProbe.$marker.withValue(expected) {
                let session = LanguageModelSession(
                    tools: [tool],
                    instructions: "You must call the task_local_probe tool exactly once."
                )
                _ = try await session.respond(
                    to: "Call the task_local_probe tool now with input 'go'."
                )
            }

            // Three distinct outcomes:
            //   • tool never called       → inconclusive (model chose not to call it — not a result)
            //   • called, observed match  → task-locals propagate → the fix works as designed
            //   • called, observed nil    → Apple severs the task tree → use explicit-propagation fallback
            guard recorder.wasCalled else {
                Issue.record("Inconclusive: the model did not call the probe tool. Re-run, or adjust the prompt.")
                return
            }

            #expect(
                recorder.observed == expected,
                """
                Apple did NOT preserve the task-local into Tool.call (observed=\(String(describing: recorder.observed))).
                The AppleAI path needs the explicit-propagation fallback (thread the parent invocation id
                through AppleAISession → RTSAppleAIToolBridge.createdBy) instead of a @TaskLocal.
                """
            )
        }
    }
}

#endif
