//
//  ObservabilityEventWriterTests.swift
//  RailtracksSwiftTests
//
//  Created by Mark Su on 2026-09-09.
//

import Combine
import Foundation
import Testing
@testable import RailtracksSwift

/// Minimal orchestrator whose body is supplied as a closure, so these tests drive the real
/// invoker → emitter → writer path with no LLM involved. Same shape as `OutputDirectoryTests`.
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

/// Collects every event a publisher emits, so a test can compare the file against the stream
/// it came from. Same shape as `ObservabilityEmissionTests`' recorder.
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

    var events: [RTSEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage
    }
}

// Serialized: these run a full `RTSFlow` and reassign the process-global
// `flowGraphOutputDirectory` and `eventsOutputDirectory`.
extension RailtracksSwiftTestSuite {

    /// Phase 3 of the observability port: the shipped receiver that writes the event stream to
    /// a JSONL file. Emission itself is covered by `ObservabilityEmissionTests` and friends.
    @Suite("Observability event writer", .serialized)
    struct ObservabilityEventWriterTests {

        // MARK: - Helpers

        /// A unique, nested directory that does not exist yet, so every test also exercises
        /// on-demand directory creation.
        private static func makeTemporaryDirectory() -> (base: URL, events: URL) {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-events-\(UUID().uuidString)", isDirectory: true)
            return (base, base.appendingPathComponent("events", isDirectory: true))
        }

        /// The JSONL file's lines, with the trailing empty component from the final newline
        /// removed.
        private static func lines(of url: URL) throws -> [String] {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return contents.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast()
                .map(String.init)
        }

        private static func decodeEvents(in url: URL) throws -> [RTSEvent] {
            let decoder = JSONDecoder()
            return try lines(of: url).map { line in
                try decoder.decode(RTSEvent.self, from: Data(line.utf8))
            }
        }

        /// How many of `events` carry `eventTypeName` — used to count runs in a file that
        /// several runs appended to.
        private static func count(
            of eventTypeName: String,
            in events: [RTSEvent]
        ) -> Int {
            events.filter { $0.eventType == eventTypeName }.count
        }

        private static func event(
            _ eventType: String,
            scopeID: String,
            payload: [String: RTSValue] = [:]
        ) -> RTSEvent {
            RTSEvent(
                eventType: eventType,
                scopeType: .session,
                scopeID: scopeID,
                payload: payload
            )
        }

        // MARK: - The suite-wide output redirect

        @Test("the event output directory is redirected away from Documents")
        func outputDirectoryIsRedirected() {
            // This suite is nested inside `RailtracksSwiftTestSuite`, so this is really about
            // `RedirectsOutput.isRecursive` reaching nested suites. `RTSFlow` builds its own
            // writer against this root, so if the trait ever stops propagating, the whole target
            // starts writing into the developer's `~/Documents`.
            //
            // Asserted as "somewhere under the temporary directory" rather than as the trait's
            // exact path: other tests in this serialized suite assign `outputDirectory`
            // themselves, and the trait's job is to cover the ones that do not.
            #expect(
                RailtracksSwift.outputDirectory.path
                    .hasPrefix(FileManager.default.temporaryDirectory.path)
            )
            #expect(
                RailtracksSwift.eventsOutputDirectory.path
                    .hasPrefix(FileManager.default.temporaryDirectory.path)
            )
            // The subfolder layout is a library invariant, not something an app composes.
            #expect(RailtracksSwift.eventsOutputDirectory.lastPathComponent == "events")
            #expect(RailtracksSwift.flowGraphOutputDirectory.lastPathComponent == "sessions")
            #expect(RailtracksSwift.evaluationOutputDirectory.lastPathComponent == "evaluations")
        }

        // MARK: - The built-in writer on RTSFlow

        /// Runs a trivial flow and returns the event types its built-in writer recorded.
        private func runAndReadBuiltInLog(_ flow: RTSFlow) async throws -> [String] {
            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let writer = try #require(flow.eventWriter)
            let url = try await publishedFileURL(writer)
            return try Self.decodeEvents(in: url).map { $0.eventType }
        }

        @Test("savesEvents follows savesTrace when it is not given", .timeLimit(.minutes(1)))
        func savesEventsFollowsSavesTrace() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let tracing = RTSFlow(title: "BuiltInFollowsTraceOn")
            #expect(tracing.eventWriter != nil)
            let recorded = try await runAndReadBuiltInLog(tracing)
            #expect(recorded.first == RTSSessionStartedEvent.eventTypeName)
            #expect(recorded.last == RTSSessionCompletedEvent.eventTypeName)

            // The evaluation-protection case: the judge's per-call sub-flows pass
            // `savesTrace: false`, so inheriting it is what keeps them from spilling one event
            // log per judged datapoint. Asserted directly rather than trusted.
            let traceless = RTSFlow(title: "BuiltInFollowsTraceOff", savesTrace: false)
            #expect(traceless.eventWriter == nil)
        }

        @Test("savesEvents overrides savesTrace in both directions")
        func savesEventsOverridesSavesTrace() async throws {
            let eventsWithoutTrace = RTSFlow(
                title: "BuiltInEventsOnly",
                savesTrace: false,
                savesEvents: true
            )
            #expect(eventsWithoutTrace.eventWriter != nil)

            let traceWithoutEvents = RTSFlow(
                title: "BuiltInTraceOnly",
                savesTrace: true,
                savesEvents: false
            )
            #expect(traceWithoutEvents.eventWriter == nil)
        }

        @Test("emitsEvents false suppresses the built-in writer whatever savesEvents says")
        func disabledEmissionSuppressesTheBuiltInWriter() {
            let flow = RTSFlow(
                title: "BuiltInNoEmission",
                savesTrace: true,
                savesEvents: true,
                emitsEvents: false
            )
            #expect(flow.eventWriter == nil)
        }

        @Test("two runs append to the built-in writer's single file", .timeLimit(.minutes(1)))
        func builtInWriterAppendsAcrossRuns() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "BuiltInAppends")
            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            let writer = try #require(flow.eventWriter)
            // Drained explicitly rather than read off `fileURLPublisher`: that subject holds the
            // *latest* close, so subscribing after run two can still hand back run one's publish
            // before run two's close has landed on the consumer task.
            let url = try #require(await writer.finish()).get()
            let written = try Self.decodeEvents(in: url)
            // One file, two runs, one scope — the re-arm path, now driven by library-owned
            // wiring rather than by the test.
            #expect(Set(written.map { $0.scopeID }).count == 1)
            #expect(Self.count(of: RTSSessionStartedEvent.eventTypeName, in: written) == 2)
            #expect(Self.count(of: RTSSessionCompletedEvent.eventTypeName, in: written) == 2)
        }

        @Test("releasing a flow releases its writer", .timeLimit(.minutes(1)))
        func flowDeinitReleasesTheWriter() async throws {
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            weak var writerAfterRelease: RTSEventWriter?
            do {
                let flow = RTSFlow(title: "BuiltInRelease")
                writerAfterRelease = try #require(flow.eventWriter)
                let root = StubOrchestrator(nodeName: "Root") { _, _ in
                    [:]
                }
                _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            }

            // The writer holds two cycles that only `finish()` breaks — its queue owns the
            // subscription whose sink captures that queue, and its consumer task retains it
            // across `for await`. `RTSFlow.deinit` breaks both; without it this stays non-nil
            // and every flow leaks its writer, queue and buffer.
            var attempts = 0
            while writerAfterRelease != nil, attempts < 100 {
                // `deinit` schedules `finish()` on a task, so the teardown lands asynchronously.
                try await Task.sleep(for: .milliseconds(20))
                attempts += 1
            }
            #expect(writerAfterRelease == nil)
        }

        @Test("a write failure on one run does not silence the next", .timeLimit(.minutes(1)))
        func writeFailureDoesNotSilenceLaterRuns() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: subject.eraseToAnyPublisher())

            // Run one fails: the path guard rejects the scope id, so `write` records a failure.
            // Driven through the scope rather than by moving the output directory mid-test —
            // the directory is resolved on the consumer task, so that would race.
            subject.send(Self.event(RTSSessionStartedEvent.eventTypeName, scopeID: "a/b"))
            subject.send(Self.event("node.creation", scopeID: "a/b"))
            subject.send(Self.event(RTSSessionCompletedEvent.eventTypeName, scopeID: "a/b"))

            // Run two is fine. A flow outlives its runs, so the earlier failure must not leave
            // the writer permanently silent.
            subject.send(Self.event(RTSSessionStartedEvent.eventTypeName, scopeID: "scope"))
            subject.send(Self.event("node.creation", scopeID: "scope"))
            subject.send(Self.event(RTSSessionCompletedEvent.eventTypeName, scopeID: "scope"))

            let url = try #require(await writer.finish()).get()
            let written = try Self.decodeEvents(in: url)
            #expect(written.map { $0.eventType } == [
                RTSSessionStartedEvent.eventTypeName,
                "node.creation",
                RTSSessionCompletedEvent.eventTypeName,
            ])
        }

        // MARK: - The AsyncStream contract the queue is built on

        @Test("bufferingNewest evicts the oldest and reports it, and finish still drains")
        func bufferingPolicySemantics() async throws {
            // The queue's drop policy is `.bufferingNewest` precisely because it *is* Python's
            // DROP_OLDEST. Pinned here against the stdlib rather than inferred from writer
            // behavior: if this ever changes, the drop accounting silently inverts.
            let (stream, continuation) = AsyncStream<Int>.makeStream(
                of: Int.self,
                bufferingPolicy: .bufferingNewest(3)
            )

            for value in 1...3 {
                guard case .enqueued = continuation.yield(value) else {
                    Issue.record("yield \(value) should have been enqueued")
                    return
                }
            }
            // Full: the next yield evicts the oldest and hands *that* element back — not the
            // one just yielded.
            guard case .dropped(let evicted) = continuation.yield(4) else {
                Issue.record("yield 4 should have dropped")
                return
            }
            #expect(evicted == 1)

            continuation.finish()
            // Terminal state, not an element, so the buffering policy cannot evict it — which
            // is why the writer needs no equivalent of Python's `_enqueue_end` eviction hack.
            guard case .terminated = continuation.yield(99) else {
                Issue.record("a yield after finish should be terminated")
                return
            }

            var delivered: [Int] = []
            for await value in stream {
                delivered.append(value)
            }
            #expect(delivered == [2, 3, 4])
        }

        // MARK: - The file matches the stream

        @Test("the file holds exactly the events the flow published, in order")
        func fileMatchesTheStream() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterMatchesStream")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)
            let recorder = EventRecorder(flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                ["result": .string("done")]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let outcome = try #require(await writer.finish())

            let url = try outcome.get()
            let written = try Self.decodeEvents(in: url)
            #expect(written.map { $0.eventID } == recorder.events.map { $0.eventID })
            #expect(
                written.map { $0.eventType } == [
                    "session.started",
                    "node.creation",
                    "node.invocation",
                    "node.response",
                    "node.destruction",
                    "session.completed",
                ]
            )
        }

        @Test("the file is complete the moment finish returns")
        func finishIsADrainBarrier() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterDrain")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let url = try #require(await writer.finish()).get()

            // Read on the very next statement: no polling, no sleep. If the barrier regresses
            // this fails deterministically rather than flakily.
            let written = try Self.decodeEvents(in: try url)
            #expect(written.last?.eventType == RTSSessionCompletedEvent.eventTypeName)
        }

        @Test("one line per event, never pretty-printed")
        func oneLinePerEvent() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterOneLine")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)
            let recorder = EventRecorder(flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                ["result": .string("multi\nline\tvalue")]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let url = try #require(await writer.finish()).get()

            // The collector and the evaluation writer both pretty-print under `#if DEBUG`, and
            // tests build in debug — so assert the format explicitly rather than trusting that
            // the habit was not copied. A payload containing a literal newline is the case that
            // would break the format if escaping ever regressed.
            let fileLines = try Self.lines(of: try url)
            #expect(fileLines.count == recorder.events.count)
            for line in fileLines {
                #expect(line.hasPrefix("{"))
                #expect(line.hasSuffix("}"))
                #expect(!line.contains("\n"))
            }
        }

        // MARK: - Files and directories

        @Test("a missing nested output directory is created on demand")
        func createsMissingOutputDirectory() async throws {
            // The events analogue of the 6029 regression covered by `OutputDirectoryTests`:
            // a missing subdirectory must be created at write time, not error out.
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            #expect(!FileManager.default.fileExists(atPath: eventsDirectory.path))
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterMakesDirectory")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let url = try #require(await writer.finish()).get()

            #expect(FileManager.default.fileExists(atPath: try url.path))
            #expect(FileManager.default.fileExists(atPath: eventsDirectory.path))
        }

        @Test("the file is named for the scope id and lives in the events directory")
        func fileIsNamedForTheScope() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterNaming")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let url = try #require(await writer.finish()).get()

            #expect(try url.lastPathComponent == "\(flow.id.uuidString).jsonl")
            #expect(try url.deletingLastPathComponent().path == eventsDirectory.path)
        }

        @Test("two runs on one flow append to a single file")
        func twoRunsAppend() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterAppends")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let url = try #require(await writer.finish()).get()

            // Both runs share the flow's `scope_id`, so they accumulate rather than overwrite —
            // the opposite of the flow-graph trace's behaviour on flow re-use.
            let written = try Self.decodeEvents(in: try url)
            let scopeIDs = Set(written.map { $0.scopeID })
            #expect(scopeIDs == [flow.id.uuidString])
            #expect(Self.count(of: RTSSessionStartedEvent.eventTypeName, in: written) == 2)
            #expect(Self.count(of: RTSSessionCompletedEvent.eventTypeName, in: written) == 2)

            let directoryContents = try FileManager.default.contentsOfDirectory(
                atPath: eventsDirectory.path
            )
            #expect(directoryContents == ["\(flow.id.uuidString).jsonl"])
        }

        // MARK: - Safety

        @Test("an unsafe scope id is refused and creates no file", arguments: [
            "",
            ".",
            "..",
            ".hidden",
            "a/b",
            "a\\b",
            "../escape",
            String(repeating: "x", count: 300),
        ])
        func unsafeScopeIDCreatesNoFile(scopeID: String) async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: subject.eraseToAnyPublisher())
            subject.send(Self.event("node.creation", scopeID: scopeID))
            let outcome = await writer.finish()

            // Nothing was opened, so there is no URL to report.
            #expect(outcome == nil || (try? outcome?.get()) == nil)
            let escaped = base.appendingPathComponent("escape.jsonl")
            #expect(!FileManager.default.fileExists(atPath: escaped.path))
            let directoryContents = (
                try? FileManager.default.contentsOfDirectory(atPath: eventsDirectory.path)
            ) ?? []
            #expect(directoryContents.isEmpty)
        }

        @Test("a NaN in the payload still produces a parseable line")
        func nonConformingFloatSurvives() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: subject.eraseToAnyPublisher())
            subject.send(
                Self.event(
                    "llm.response",
                    scopeID: "scope",
                    payload: ["latency": .number(Double.nan)]
                )
            )
            let url = try #require(await writer.finish()).get()

            // The default `.throw` strategy would have lost the whole event.
            let fileLines = try Self.lines(of: try url)
            #expect(fileLines.count == 1)
            let parsed = try JSONSerialization.jsonObject(
                with: Data(try #require(fileLines.first).utf8)
            )
            let object = try #require(parsed as? [String: Any])
            let payload = try #require(object["payload"] as? [String: Any])
            #expect(payload["latency"] as? String == "NaN")
        }

        @Test("an unwritable directory never breaks the run", .timeLimit(.minutes(1)))
        func unwritableDirectoryIsNotFatal() async throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("rts-events-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // A regular file where the writer expects a directory: `createDirectory` fails.
            let blocker = base.appendingPathComponent("blocked")
            try Data("not a directory".utf8).write(to: blocker)
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterUnwritable")
            let writer = RTSEventWriter(directory: blocker.appendingPathComponent("events"))
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                ["result": .string("ok")]
            }
            // Observability must never break execution: the run completes normally.
            let output = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            #expect(output["result"] == .string("ok"))

            let outcome = await writer.finish()
            guard case .failure = try #require(outcome) else {
                Issue.record("expected the writer to report its write failure")
                return
            }
            // The publisher must agree with `finish()`. A write failure skips the auto-close, so
            // the handle is swept at teardown — and that sweep must not announce a broken log as
            // a finished one.
            for await published in writer.fileURLPublisher.values {
                guard case .failure = published else {
                    Issue.record("fileURLPublisher reported success for a failed write")
                    return
                }
                break
            }
        }

        // MARK: - Lifetime

        @Test("finish is idempotent and reports the same outcome")
        func finishIsIdempotent() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: subject.eraseToAnyPublisher())
            subject.send(Self.event("node.creation", scopeID: "scope"))

            let first = try #require(await writer.finish()).get()
            let second = try #require(await writer.finish()).get()
            #expect(try first == second)
            #expect(try Self.lines(of: first).count == 1)
        }

        /// The first file the writer publishes, i.e. the first run to close one.
        private func publishedFileURL(_ writer: RTSEventWriter) async throws -> URL {
            for await outcome in writer.fileURLPublisher.values {
                return try outcome.get()
            }
            struct NoPublishedFile: Error {
            }
            throw NoPublishedFile()
        }

        @Test(
            "session.completed closes the file and publishes it, with no finish call",
            .timeLimit(.minutes(1))
        )
        func autoClosesOnSessionCompleted() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterAutoClose")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))

            // No `finish()`: the run's terminal event closes the file on its own, mirroring the
            // Python engine's per-call writer shutdown.
            let url = try await publishedFileURL(writer)
            let written = try Self.decodeEvents(in: url)
            #expect(written.last?.eventType == RTSSessionCompletedEvent.eventTypeName)
        }

        @Test(
            "the writer re-arms, so a second run appends to the same file",
            .timeLimit(.minutes(1))
        )
        func reArmsAfterAutoClose() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterReArm")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let url = try await publishedFileURL(writer)
            let afterFirstRun = try Self.decodeEvents(in: url).count

            // Closing on `session.completed` must not end the subscription: the second run has
            // to reopen the same path in append mode, as Python's per-call shutdown does.
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            _ = await writer.finish()

            let written = try Self.decodeEvents(in: url)
            #expect(written.count == afterFirstRun * 2)
            #expect(Self.count(of: RTSSessionCompletedEvent.eventTypeName, in: written) == 2)
            let directoryContents = try FileManager.default.contentsOfDirectory(
                atPath: eventsDirectory.path
            )
            #expect(directoryContents == ["\(flow.id.uuidString).jsonl"])
        }

        @Test("an event arriving after its run's session.completed is counted as late")
        func lateArrivalIsFlagged() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: subject.eraseToAnyPublisher())

            subject.send(Self.event(RTSSessionStartedEvent.eventTypeName, scopeID: "scope"))
            subject.send(Self.event(RTSSessionCompletedEvent.eventTypeName, scopeID: "scope"))
            // Outlived its own run's terminal marker — the shape a fire-and-forget emit site
            // would produce. Nothing is lost (the file reopens in append mode), but the file
            // was already published as complete, so it must not pass silently.
            subject.send(Self.event("llm.response", scopeID: "scope"))
            let url = try #require(await writer.finish()).get()

            #expect(await writer.lateEventCount == 1)
            let written = try Self.decodeEvents(in: try url)
            #expect(written.map { $0.eventType } == [
                "session.started",
                "session.completed",
                "llm.response",
            ])
        }

        @Test("a second run's session.started reopens the log without being flagged")
        func newRunIsNotFlaggedAsLate() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: subject.eraseToAnyPublisher())

            for _ in 0..<2 {
                subject.send(Self.event(RTSSessionStartedEvent.eventTypeName, scopeID: "scope"))
                subject.send(Self.event(RTSSessionCompletedEvent.eventTypeName, scopeID: "scope"))
            }
            _ = try #require(await writer.finish()).get()

            // Reopening for a new run is the legitimate case and must stay silent, or the
            // diagnostic would fire on every multi-run flow and be worthless.
            #expect(await writer.lateEventCount == 0)
        }

        @Test("overlapping runs on one flow are flagged, sequential ones are not")
        func overlappingRunsAreFlagged() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: subject.eraseToAnyPublisher())

            // Two sequential brackets: the file closes between them, so this is the ordinary
            // re-arm path and must not count.
            for _ in 0..<2 {
                subject.send(Self.event(RTSSessionStartedEvent.eventTypeName, scopeID: "scope"))
                subject.send(Self.event(RTSSessionCompletedEvent.eventTypeName, scopeID: "scope"))
            }
            // Then a second `session.started` while the bracket is still open — two `run` calls
            // in flight on one flow.
            subject.send(Self.event(RTSSessionStartedEvent.eventTypeName, scopeID: "scope"))
            subject.send(Self.event(RTSSessionStartedEvent.eventTypeName, scopeID: "scope"))
            subject.send(Self.event(RTSSessionCompletedEvent.eventTypeName, scopeID: "scope"))
            _ = await writer.finish()

            // Exactly one: the three sequential starts must contribute nothing, so a count of 3
            // would mean the detector is firing on the ordinary re-arm path too.
            #expect(await writer.overlappingRunEventCount == 1)
        }

        @Test("a writer is one-shot: a run after finish is not recorded")
        func writerIsOneShot() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterOneShot")
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let url = try #require(await writer.finish()).get()
            let afterFirstRun = try Self.decodeEvents(in: try url)

            // `finish()` cancels the subscription and terminates the queue permanently, so a
            // second run publishes into a dead stream. Pinned because the tempting mistake is
            // to call `finish()` after every run and assume append mode picks it back up.
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            _ = await writer.finish()

            #expect(try Self.decodeEvents(in: try url).count == afterFirstRun.count)
            #expect(Self.count(of: RTSSessionStartedEvent.eventTypeName, in: afterFirstRun) == 1)
        }

        @Test("a writer that was never subscribed writes nothing")
        func neverSubscribedWritesNothing() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let writer = RTSEventWriter(directory: eventsDirectory)
            let outcome = await writer.finish()

            #expect(outcome == nil)
            #expect(!FileManager.default.fileExists(atPath: eventsDirectory.path))
        }

        @Test("a flow built with emitsEvents false writes nothing")
        func disabledEmissionWritesNothing() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterDisabled", emitsEvents: false)
            let writer = RTSEventWriter(directory: eventsDirectory)
            writer.subscribe(to: flow.eventPublisher)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            let outcome = await writer.finish()

            #expect(outcome == nil)
            #expect(!FileManager.default.fileExists(atPath: eventsDirectory.path))
        }

        @Test("subscribing after a run has begun loses the head of the stream")
        func lateSubscriptionLosesTheHead() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }
            RailtracksSwift.outputDirectory = FileManager.default.temporaryDirectory

            let flow = RTSFlow(title: "WriterLate")
            let writer = RTSEventWriter(directory: eventsDirectory)

            let root = StubOrchestrator(nodeName: "Root") { _, _ in
                [:]
            }
            // Deliberately subscribed after the run: `eventPublisher` is a plain
            // `PassthroughSubject` with no replay. This pins the documented contract — attach
            // the writer before `run` — so the behaviour is asserted rather than discovered.
            _ = try await flow.run(root, input: [:], gateway: RTSLLMGateway(apiKeys: [:]))
            writer.subscribe(to: flow.eventPublisher)
            let outcome = await writer.finish()

            #expect(outcome == nil)
        }

        // MARK: - The bounded queue

        @Test("a saturated queue drops events but never loses count of them")
        func saturatedQueueConservesTheCount() async throws {
            let (base, eventsDirectory) = Self.makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: base)
            }

            let eventCount = 500
            let subject = PassthroughSubject<RTSEvent, Never>()
            let writer = RTSEventWriter(directory: eventsDirectory, queueCapacity: 4)
            writer.subscribe(to: subject.eraseToAnyPublisher())
            for index in 0..<eventCount {
                subject.send(
                    Self.event(
                        "node.creation",
                        scopeID: "scope",
                        payload: ["index": .number(Double(index))]
                    )
                )
            }
            let url = try #require(await writer.finish()).get()

            // Whatever the interleaving, every event is either written or counted as dropped —
            // nothing vanishes silently. That conservation is the property worth pinning; the
            // exact split depends on how fast the consumer drains.
            let written = await writer.lineCount
            let dropped = await writer.droppedEventCount
            #expect(written + dropped == eventCount)
            #expect(try Self.lines(of: url).count == written)
        }
    }
}
