//
//  RunCancellationTests.swift
//  RailtracksSwiftTests
//

import Combine
import Foundation
import FoundationModels
import Testing
@testable import RailtracksSwift

/// Minimal orchestrator whose body is supplied as a closure, so these tests drive a real
/// `RTSFlow` with no LLM involved. Same shape as `ErrorReportingTests`.
private struct StubOrchestrator: RTSOrchestratorNode {
    let id = UUID()
    var inputs: RTSInput = [:]
    let nodeName: String
    let body: @Sendable (RTSInput, RTSRunContext) async throws -> RTSOutput

    func name() -> String {
        nodeName
    }

    func run(_ input: RTSInput, context: RTSRunContext) async throws -> RTSOutput {
        try await body(input, context)
    }
}

/// Lets a test wait until a node's body has started, so it cancels a run that is really running.
private final class StartSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func fire() {
        continuation.yield()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}

/// Records whether a node's body ever ran.
private final class RanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var didRun: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }
}

/// Collects every event a flow publishes, for assertions after the run.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RTSEvent] = []
    private var cancellable: AnyCancellable?

    init(_ publisher: AnyPublisher<RTSEvent, Never>) {
        cancellable = publisher.sink { [weak self] event in
            guard let self else {
                return
            }
            self.lock.lock()
            self.storage.append(event)
            self.lock.unlock()
        }
    }

    func first(ofType eventType: String) -> RTSEvent? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage.first { $0.eventType == eventType }
    }
}

/// Captures the trace-write result as soon as the flow publishes it, so a test can check whether
/// the trace was already written at the moment `run` returned.
private final class TraceURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<URL, Error>?
    private var cancellable: AnyCancellable?

    init(_ publisher: AnyPublisher<Result<URL, Error>, Never>) {
        cancellable = publisher.sink { [weak self] result in
            guard let self else {
                return
            }
            self.lock.lock()
            self.result = result
            self.lock.unlock()
        }
    }

    var writtenURL: URL? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard case .success(let url)? = result else {
            return nil
        }
        return url
    }
}

/// Records each node's last reported state. `nodeStatusPublisher` delivers on its own queue, which
/// `run` doesn't wait for, so a test waits for the state it expects.
private final class NodeStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: RTSNodeStatus.State] = [:]
    private var cancellable: AnyCancellable?

    init(_ publisher: AnyPublisher<RTSNodeStatus, Never>) {
        cancellable = publisher.sink { [weak self] status in
            guard let self else {
                return
            }
            self.lock.lock()
            self.states[status.nodeName] = status.state
            self.lock.unlock()
        }
    }

    /// `nodeName`'s state once it has finished, waiting up to `timeout` for delivery.
    func finalState(
        of nodeName: String,
        timeout: Duration = .seconds(2)
    ) async -> RTSNodeStatus.State? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let state = state(of: nodeName), Self.isFinal(state) {
                return state
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return state(of: nodeName)
    }

    private func state(of nodeName: String) -> RTSNodeStatus.State? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return states[nodeName]
    }

    private static func isFinal(_ state: RTSNodeStatus.State) -> Bool {
        switch state {
        case .queued, .executing:
            return false
        case .completed, .failed, .cancelled:
            return true
        }
    }
}

private func isCancelledState(_ state: RTSNodeStatus.State?) -> Bool {
    guard case .cancelled? = state else {
        return false
    }
    return true
}

private func isCancelledRun(_ error: Error?) -> Bool {
    guard let error else {
        return false
    }
    return RTSRunCancellation.isCancellation(error)
}

// Serialized: these tests run a full `RTSFlow`, which touches process-global state
// (`flowGraphOutputDirectory`, the shared Instruments signpost API).
extension RailtracksSwiftTestSuite {
    @Suite("Run cancellation", .serialized)
    struct RunCancellationTests {

        /// Runs `root` in a task, cancels it once `started` fires, and returns what the run threw.
        private func cancelWhileRunning(
            _ flow: RTSFlow,
            root: some RTSOrchestratorNode,
            started: StartSignal
        ) async -> Error? {
            let run = Task {
                try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            }
            await started.wait()
            run.cancel()
            do {
                _ = try await run.value
                return nil
            } catch {
                return error
            }
        }

        /// Cancelling the task stops a node that is waiting, and the run reports the one
        /// cancelled shape, not the `CancellationError` `Task.sleep` threw.
        @Test("cancelling the task stops the run with runTerminated(cancelled)")
        func cancellingStopsTheRun() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let started = StartSignal()
            let root = StubOrchestrator(nodeName: "Slow") { _, _ in
                started.fire()
                try await Task.sleep(for: .seconds(30))
                return ["result": .string("never")]
            }
            let flow = RTSFlow(title: "CancelSlowNode", savesTrace: false)

            let clock = ContinuousClock()
            let begin = clock.now
            let thrown = await cancelWhileRunning(flow, root: root, started: started)
            let elapsed = clock.now - begin

            #expect(isCancelledRun(thrown), "expected runTerminated(cancelled), got \(String(describing: thrown))")
            #expect(elapsed < .seconds(5), "the run should stop promptly, took \(elapsed)")
        }

        /// A cancelled run writes its trace and `session.completed` **before** `run` returns, with
        /// the root node failed and the cancellation as its error. Checked at the moment `run`
        /// returns: waiting on the publisher afterwards would also accept a trace written late.
        @Test("a cancelled run writes its trace and session.completed before returning")
        func cancelledRunStillFinishesItsTrace() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let started = StartSignal()
            let root = StubOrchestrator(nodeName: "Slow") { _, _ in
                started.fire()
                try await Task.sleep(for: .seconds(30))
                return ["result": .string("never")]
            }
            let flow = RTSFlow(title: "CancelTrace")
            let recorder = EventRecorder(flow.eventPublisher)
            let traceURL = TraceURLRecorder(flow.outputFileURLPublisher)

            let thrown = await cancelWhileRunning(flow, root: root, started: started)
            let urlWhenRunReturned = traceURL.writtenURL
            #expect(isCancelledRun(thrown))

            let url = try #require(urlWhenRunReturned, "the trace must be written before run returns")
            let data = try Data(contentsOf: url)
            let graph = try JSONDecoder().decode(RTSFlowGraph.self, from: data)
            let run = try #require(graph.runs.first, "trace should contain a run")
            #expect(run.status == .failed)
            // The trace has no stopped status of its own, so the reason lives in the error text.
            let traceText = try #require(String(data: data, encoding: .utf8))
            #expect(traceText.contains("runTerminated(reason: cancelled)"))

            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["status"] == .string("failure"))
            #expect(completed.payload["error"] == .string("runTerminated(reason: cancelled)"))
            #expect(completed.payload["fatal"] == .bool(false))
            #expect(completed.payload["termination_reason"] == .string("cancelled"))
        }

        /// The node that was running when the run was cancelled, and a node reached after it, both
        /// report `.cancelled` rather than `.failed`.
        @Test("a cancelled run reports its nodes as cancelled")
        func cancelledRunReportsCancelledNodes() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let started = StartSignal()
            let child = StubOrchestrator(nodeName: "Child") { _, _ in
                ["result": .string("ran")]
            }
            let root = StubOrchestrator(nodeName: "IgnoresCancel") { _, context in
                started.fire()
                try? await Task.sleep(for: .seconds(30))
                return try await context.call(child, input: [:])
            }
            let flow = RTSFlow(title: "CancelNodeStatus", savesTrace: false)
            let statuses = NodeStatusRecorder(flow.nodeStatusPublisher)

            let thrown = await cancelWhileRunning(flow, root: root, started: started)

            #expect(isCancelledRun(thrown))
            let rootState = await statuses.finalState(of: "IgnoresCancel")
            let childState = await statuses.finalState(of: "Child")
            #expect(isCancelledState(rootState), "root should be cancelled, got \(String(describing: rootState))")
            #expect(isCancelledState(childState), "child should be cancelled, got \(String(describing: childState))")
        }

        /// An ordinary failure is neither fatal nor a stop: no termination reason, and the node
        /// reports `.failed` with its error.
        @Test("an ordinary failure has no termination reason and reports the node as failed")
        func ordinaryFailureIsNotATermination() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let root = StubOrchestrator(nodeName: "Throws") { _, _ in
                throw URLError(.badServerResponse)
            }
            let flow = RTSFlow(title: "OrdinaryFailure", savesTrace: false)
            let recorder = EventRecorder(flow.eventPublisher)
            let statuses = NodeStatusRecorder(flow.nodeStatusPublisher)

            _ = try? await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["status"] == .string("failure"))
            #expect(completed.payload["fatal"] == .bool(false))
            #expect(completed.payload["termination_reason"] == .null)
            let rootState = await statuses.finalState(of: "Throws")
            guard case .failed? = rootState else {
                Issue.record("expected .failed, got \(String(describing: rootState))")
                return
            }
        }

        /// A node body that ignores cancellation still can't start more work: the next node it
        /// calls is created and finished, but its body never runs.
        @Test("a cancelled run stops at the next node even if a body ignores cancellation")
        func cancelledRunStopsAtTheNextNode() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let started = StartSignal()
            let childRan = RanFlag()
            let child = StubOrchestrator(nodeName: "Child") { _, _ in
                childRan.set()
                return ["result": .string("ran")]
            }
            let root = StubOrchestrator(nodeName: "IgnoresCancel") { _, context in
                started.fire()
                // Swallows the cancellation, like a tool that never checks for it.
                try? await Task.sleep(for: .seconds(30))
                return try await context.call(child, input: [:])
            }
            let flow = RTSFlow(title: "CancelNextNode", savesTrace: false)

            let thrown = await cancelWhileRunning(flow, root: root, started: started)

            #expect(isCancelledRun(thrown), "expected runTerminated(cancelled), got \(String(describing: thrown))")
            #expect(!childRan.didRun, "the child's body must not run after the run was cancelled")
        }

        /// A `CancellationError` thrown by the app's own code, while nothing cancelled the run, is
        /// the app's error and comes through as itself.
        @Test("an app's own CancellationError passes through when the run wasn't cancelled")
        func ownCancellationErrorPassesThrough() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let root = StubOrchestrator(nodeName: "ThrowsItsOwn") { _, _ in
                throw CancellationError()
            }
            let flow = RTSFlow(title: "OwnCancellationError", savesTrace: false)

            var thrown: Error?
            do {
                _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            } catch {
                thrown = error
            }

            #expect(thrown is CancellationError, "expected CancellationError, got \(String(describing: thrown))")
        }
    }
}

private func isTimedOutRun(_ error: Error?) -> Bool {
    guard case .timeout? = RTSRunCancellation.terminationReason(of: error) else {
        return false
    }
    return true
}

extension RailtracksSwiftTestSuite {
    @Suite("Run timeout", .serialized)
    struct RunTimeoutTests {

        /// Runs `root` on `flow` and returns what it threw, or `nil` when it returned.
        private func runCapturingError(
            _ flow: RTSFlow,
            root: some RTSOrchestratorNode
        ) async -> Error? {
            do {
                _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
                return nil
            } catch {
                return error
            }
        }

        /// A node still running at the deadline is stopped, and the run reports the timeout
        /// everywhere: the thrown error, `session.started` / `session.completed`, the node's status
        /// and the trace's error text.
        @Test("a run past its timeout stops with runTerminated(timeout)")
        func timeoutStopsTheRun() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let root = StubOrchestrator(nodeName: "Slow") { _, _ in
                try await Task.sleep(for: .seconds(30))
                return ["result": .string("never")]
            }
            let flow = RTSFlow(title: "TimeoutSlowNode", timeout: 0.2)
            let recorder = EventRecorder(flow.eventPublisher)
            let statuses = NodeStatusRecorder(flow.nodeStatusPublisher)
            let traceURL = TraceURLRecorder(flow.outputFileURLPublisher)

            let clock = ContinuousClock()
            let begin = clock.now
            let thrown = await runCapturingError(flow, root: root)
            let elapsed = clock.now - begin

            #expect(isTimedOutRun(thrown), "expected runTerminated(timeout), got \(String(describing: thrown))")
            #expect(elapsed < .seconds(5), "the run should stop promptly after the deadline, took \(elapsed)")

            let started = try #require(recorder.first(ofType: "session.started"))
            #expect(started.payload["timeout"] == .number(0.2))
            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["error"] == .string("runTerminated(reason: timeout(after: 0.2))"))
            #expect(completed.payload["fatal"] == .bool(true))
            #expect(completed.payload["termination_reason"] == .string("timeout"))

            let rootState = await statuses.finalState(of: "Slow")
            #expect(isCancelledState(rootState), "a timed-out node is cancelled, got \(String(describing: rootState))")

            let url = try #require(traceURL.writtenURL, "the trace must be written before run returns")
            let traceText = try String(contentsOf: url, encoding: .utf8)
            #expect(traceText.contains("runTerminated(reason: timeout(after: 0.2))"))
        }

        /// A body that swallows the cancellation can't start another node after the deadline, and
        /// that node reports the timeout too.
        @Test("no node starts after the deadline, even if a body ignores cancellation")
        func noNodeStartsAfterTheDeadline() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let childRan = RanFlag()
            let child = StubOrchestrator(nodeName: "Child") { _, _ in
                childRan.set()
                return ["result": .string("ran")]
            }
            let root = StubOrchestrator(nodeName: "IgnoresCancel") { _, context in
                try? await Task.sleep(for: .seconds(30))
                return try await context.call(child, input: [:])
            }
            let flow = RTSFlow(title: "TimeoutNextNode", savesTrace: false, timeout: 0.2)
            let statuses = NodeStatusRecorder(flow.nodeStatusPublisher)

            let thrown = await runCapturingError(flow, root: root)

            #expect(isTimedOutRun(thrown), "expected runTerminated(timeout), got \(String(describing: thrown))")
            #expect(!childRan.didRun, "the child's body must not run after the deadline")
            let childState = await statuses.finalState(of: "Child")
            #expect(isCancelledState(childState), "the child should be cancelled, got \(String(describing: childState))")
        }

        /// A run that finishes inside its timeout is untouched: it returns its output, and the
        /// events report the timeout setting but no termination.
        @Test("a run within its timeout returns normally")
        func runWithinTimeoutReturns() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let root = StubOrchestrator(nodeName: "Fast") { _, _ in
                ["result": .string("done")]
            }
            let flow = RTSFlow(title: "TimeoutFastNode", savesTrace: false, timeout: 30)
            let recorder = EventRecorder(flow.eventPublisher)

            let output = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            #expect(output["result"] == .string("done"))
            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["status"] == .string("success"))
            #expect(completed.payload["fatal"] == .bool(false))
            #expect(completed.payload["termination_reason"] == .null)
        }

        /// A flow can be re-run with a different timeout. A change made while a run is going doesn't
        /// reach that run, which keeps the deadline it started with; the next run uses the new one.
        @Test("a timeout change applies to later runs, not the one already going")
        func timeoutChangeAppliesToLaterRuns() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let started = StartSignal()
            let root = StubOrchestrator(nodeName: "Slow") { _, _ in
                started.fire()
                try await Task.sleep(for: .seconds(30))
                return ["result": .string("never")]
            }
            let flow = RTSFlow(title: "TimeoutAdjusted", savesTrace: false, timeout: 0.3)

            let first = Task {
                await runCapturingError(flow, root: root)
            }
            await started.wait()
            // Too long to fire within the test; the running run must ignore it.
            flow.timeout = 30
            let firstThrown = await first.value

            guard case .timeout(let firstLimit)? = RTSRunCancellation.terminationReason(of: firstThrown) else {
                Issue.record("expected the first run to time out, got \(String(describing: firstThrown))")
                return
            }
            #expect(firstLimit == 0.3, "the running run keeps the timeout it started with")

            flow.timeout = 0.1
            let secondThrown = await runCapturingError(flow, root: root)

            guard case .timeout(let secondLimit)? = RTSRunCancellation.terminationReason(of: secondThrown) else {
                Issue.record("expected the second run to time out, got \(String(describing: secondThrown))")
                return
            }
            #expect(secondLimit == 0.1, "a later run uses the new timeout")
        }

        /// The app cancelling a run that has a timeout is a user cancel, not a timeout.
        @Test("cancelling a run that has a timeout reports cancelled")
        func cancelBeforeTheDeadlineIsACancel() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory
            let started = StartSignal()
            let root = StubOrchestrator(nodeName: "Slow") { _, _ in
                started.fire()
                try await Task.sleep(for: .seconds(30))
                return ["result": .string("never")]
            }
            let flow = RTSFlow(title: "TimeoutThenCancel", savesTrace: false, timeout: 20)
            let recorder = EventRecorder(flow.eventPublisher)

            let run = Task {
                try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            }
            await started.wait()
            let clock = ContinuousClock()
            let cancelledAt = clock.now
            run.cancel()
            var thrown: Error?
            do {
                _ = try await run.value
            } catch {
                thrown = error
            }
            let stopTime = clock.now - cancelledAt

            #expect(isCancelledRun(thrown), "expected runTerminated(cancelled), got \(String(describing: thrown))")
            #expect(stopTime < .seconds(5), "the run should stop promptly after cancel, took \(stopTime)")
            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["fatal"] == .bool(false))
            #expect(completed.payload["termination_reason"] == .string("cancelled"))
        }
    }
}

extension RailtracksSwiftTestSuite {
    @Suite("Run cancellation, live", .serialized)
    struct RunCancellationLiveTests {

        /// Cancels a real on-device generation partway through and measures how long the run takes
        /// to stop: whether FoundationModels' `respond` honours cancellation, or the run only stops
        /// once the response is finished. Skips when the on-device model is unavailable.
        @Test("cancelling a live AppleAI run stops it promptly")
        func cancellingALiveAppleAIRun() async throws {
            guard #available(macOS 26, iOS 26, *) else {
                print("⏭️  live AppleAI cancellation skipped — requires macOS 26 / iOS 26.")
                return
            }
            let availability = SystemLanguageModel.default.availability
            guard case .available = availability else {
                print("⏭️  live AppleAI cancellation skipped — on-device model unavailable: \(availability).")
                return
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let agent = RTSAgent(llmProvider: .appleAI, name: "Essayist")
            let flow = RTSFlow(title: "CancelLiveAppleAI", savesTrace: false)
            let run = Task {
                try await flow.run(
                    agent: agent,
                    prompt: "Write a detailed 1500-word essay on the history of railways.",
                    gateway: RTSLLMGateway(apiKeys: [:])
                )
            }
            try await Task.sleep(for: .seconds(1))

            let clock = ContinuousClock()
            let cancelledAt = clock.now
            run.cancel()
            var thrown: Error?
            do {
                _ = try await run.value
            } catch {
                thrown = error
            }
            let stopTime = clock.now - cancelledAt
            print("🛑 live AppleAI run stopped \(stopTime) after cancel; threw \(String(describing: thrown))")

            #expect(isCancelledRun(thrown), "expected runTerminated(cancelled), got \(String(describing: thrown))")
            #expect(stopTime < .seconds(5), "the run should stop promptly after cancel, took \(stopTime)")
        }

        /// A real on-device generation that outlasts the flow's timeout is stopped at the deadline
        /// and reports the timeout. Skips when the on-device model is unavailable.
        @Test("a live AppleAI run past its timeout stops promptly")
        func liveAppleAIRunTimesOut() async throws {
            guard #available(macOS 26, iOS 26, *) else {
                print("⏭️  live AppleAI timeout skipped — requires macOS 26 / iOS 26.")
                return
            }
            let availability = SystemLanguageModel.default.availability
            guard case .available = availability else {
                print("⏭️  live AppleAI timeout skipped — on-device model unavailable: \(availability).")
                return
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let agent = RTSAgent(llmProvider: .appleAI, name: "Essayist")
            let flow = RTSFlow(title: "TimeoutLiveAppleAI", savesTrace: false, timeout: 1)
            let clock = ContinuousClock()
            let begin = clock.now
            var thrown: Error?
            do {
                _ = try await flow.run(
                    agent: agent,
                    prompt: "Write a detailed 1500-word essay on the history of railways.",
                    gateway: RTSLLMGateway(apiKeys: [:])
                )
            } catch {
                thrown = error
            }
            let elapsed = clock.now - begin
            print("⏱️ live AppleAI run with a 1 s timeout returned after \(elapsed); threw \(String(describing: thrown))")

            #expect(isTimedOutRun(thrown), "expected runTerminated(timeout), got \(String(describing: thrown))")
            #expect(elapsed < .seconds(5), "the run should stop promptly after the deadline, took \(elapsed)")
        }
    }
}

@Suite struct RunCancellationNormalizationTests {
    /// Outside a cancelled task, any error is left alone.
    @Test func anErrorIsUnchangedWhenNotCancelled() {
        let error = URLError(.cancelled)

        let normalized = RTSRunCancellation.normalized(error, stopReason: nil)

        #expect(normalized is URLError)
    }

    /// Inside a cancelled task, a provider's own cancel error becomes the one cancelled shape.
    @Test func aProviderCancelErrorBecomesTheCancelledShape() async {
        let task = Task { () -> Error in
            while !Task.isCancelled {
                await Task.yield()
            }
            return RTSRunCancellation.normalized(URLError(.cancelled), stopReason: nil)
        }
        task.cancel()

        let normalized = await task.value

        #expect(RTSRunCancellation.isCancellation(normalized))
    }

    /// When the run stopped itself, the recorded reason is reported instead of `.cancelled`.
    @Test func aRecordedStopReasonIsReported() async {
        let task = Task { () -> Error in
            while !Task.isCancelled {
                await Task.yield()
            }
            return RTSRunCancellation.normalized(URLError(.cancelled), stopReason: .timeout(after: 5))
        }
        task.cancel()

        let normalized = await task.value

        guard case .timeout? = RTSRunCancellation.terminationReason(of: normalized) else {
            Issue.record("expected the recorded timeout, got \(normalized)")
            return
        }
    }

    /// The first stop requested is the one kept.
    @Test func theFirstStopRequestWins() {
        let stop = RTSRunStop()

        let first = stop.request(.timeout(after: 5))
        let second = stop.request(.cancelled)

        #expect(first)
        #expect(!second)
        guard case .timeout? = stop.reason else {
            Issue.record("expected the first stop, got \(String(describing: stop.reason))")
            return
        }
    }

    /// A cancel and a timeout both stop a node from outside, so both report `.cancelled`.
    @Test func cancelAndTimeoutFinishAsCancelled() {
        let cancelled = finishEvent(error: RTSError.runTerminated(reason: .cancelled))
        let timedOut = finishEvent(error: RTSError.runTerminated(reason: .timeout(after: 5)))

        #expect(isCancelledState(RTSFlow.finishedState(of: cancelled)))
        #expect(isCancelledState(RTSFlow.finishedState(of: timedOut)))
    }

    /// An end-on-error stop is a failure, with the error text; no error at all is a completion.
    @Test func endOnErrorFinishesAsFailedAndSuccessAsCompleted() {
        let reason = RTSRunTerminationReason.endOnError(
            nodeName: "Tool",
            underlying: URLError(.badServerResponse)
        )
        let endOnError = finishEvent(error: RTSError.runTerminated(reason: reason))
        let succeeded = finishEvent(error: nil)

        guard case .failed(let message) = RTSFlow.finishedState(of: endOnError) else {
            Issue.record("expected .failed for an end-on-error stop")
            return
        }
        #expect(message.contains("endOnError"))
        guard case .completed = RTSFlow.finishedState(of: succeeded) else {
            Issue.record("expected .completed with no error")
            return
        }
    }

    /// A finish event the way `RTSNodeInvoker` builds one for `error`.
    private func finishEvent(error: Error?) -> RTSNodeEvent {
        RTSNodeEvent(
            nodeID: UUID(),
            name: "Node",
            nodeType: .tool,
            stamp: RTSStamp(stepIndex: 0, event: .finishExecution("Node")),
            error: error.map { "\($0)" },
            terminationReason: RTSRunCancellation.terminationReason(of: error)
        )
    }

    /// An error that already says how the run stopped is kept: the first stop observed wins.
    @Test func anExistingTerminationIsKept() async {
        let task = Task { () -> Error in
            while !Task.isCancelled {
                await Task.yield()
            }
            return RTSRunCancellation.normalized(
                RTSError.runTerminated(reason: .timeout(after: 5)),
                stopReason: nil
            )
        }
        task.cancel()

        let normalized = await task.value

        guard case .runTerminated(let reason, _)? = normalized as? RTSError,
              case .timeout = reason else {
            Issue.record("expected the timeout to be kept, got \(normalized)")
            return
        }
    }
}
