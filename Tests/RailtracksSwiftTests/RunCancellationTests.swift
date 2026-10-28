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
            let graph = try JSONDecoder().decode(RTSFlowGraph.self, from: Data(contentsOf: url))
            let run = try #require(graph.runs.first, "trace should contain a run")
            #expect(run.status == .failed)

            let completed = try #require(recorder.first(ofType: "session.completed"))
            #expect(completed.payload["status"] == .string("failure"))
            #expect(completed.payload["error"] == .string("runTerminated(reason: cancelled)"))
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
    }
}

@Suite struct RunCancellationNormalizationTests {
    /// Outside a cancelled task, any error is left alone.
    @Test func anErrorIsUnchangedWhenNotCancelled() {
        let error = URLError(.cancelled)

        let normalized = RTSRunCancellation.normalized(error)

        #expect(normalized is URLError)
    }

    /// Inside a cancelled task, a provider's own cancel error becomes the one cancelled shape.
    @Test func aProviderCancelErrorBecomesTheCancelledShape() async {
        let task = Task { () -> Error in
            while !Task.isCancelled {
                await Task.yield()
            }
            return RTSRunCancellation.normalized(URLError(.cancelled))
        }
        task.cancel()

        let normalized = await task.value

        #expect(RTSRunCancellation.isCancellation(normalized))
    }

    /// An error that already says how the run stopped is kept: the first stop observed wins.
    @Test func anExistingTerminationIsKept() async {
        let task = Task { () -> Error in
            while !Task.isCancelled {
                await Task.yield()
            }
            return RTSRunCancellation.normalized(RTSError.runTerminated(reason: .timeout(after: 5)))
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
