//
//  RTSEventWriter.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-09.
//

import Combine
import Foundation

// MARK: - RTSEventWriter

/// Appends the observability event stream to a JSONL file — one JSON object per line,
/// `<scope_id>.jsonl` under ``RailtracksSwift/eventsOutputDirectory``.
///
/// Mirrors the Python engine's `JsonlWriter` (`observability/writers/jsonl/jsonl.py`) and its
/// observer's queueing (`observability/observer.py`), collapsed into one type because Swift's
/// event stream is already a multicast Combine publisher — the fan-out, registry and inline
/// listener tiers Python builds by hand are what `eventPublisher` already is.
///
/// The library ships this writer; **the app owns its setup and its lifetime**:
///
/// ```swift
/// let flow = RTSFlow(title: "Support")
/// let eventWriter = RTSEventWriter()
/// eventWriter.subscribe(to: flow.eventPublisher)
/// let answer = try await flow.run(agent: agent, prompt: prompt, gateway: gateway)
/// ```
///
/// **The file closes itself.** Each run ends with `session.completed`, and writing that event
/// closes the file and publishes it on ``fileURLPublisher`` — mirroring the Python engine,
/// which drains and shuts its writers down in the `finally` of every top-level call. The
/// subscription stays live afterwards, so a second run on the same flow reopens the same file
/// in append mode. Nothing has to be remembered per run.
///
/// So ``finish()`` is teardown, not a correctness step: call it when the writer is done with
/// for good, to drop the subscription and close a file left open by a run that never finished.
///
/// Any number of other receivers can subscribe to the same publisher alongside it and process
/// the stream however they like — this writer claims no exclusivity over it.
///
/// One contract the caller has to honour, a consequence of app-side ownership:
/// **subscribe before calling `run`.** `eventPublisher` is a plain `PassthroughSubject` with no
/// replay, so a writer attached after a run has begun silently loses `session.started` and
/// everything before it. Attach it as soon as the flow exists.
///
/// To *read* a file, wait for it on ``fileURLPublisher`` rather than assuming it is closed the
/// instant `run` returns. Every event is enqueued synchronously before `run` returns, but the
/// consumer writes them on its own task, so the close lands a moment later.
///
/// Nothing here throws. Observability must never break a run, so a failure degrades to a log
/// line and a counter — the same rule the emitter follows.
public actor RTSEventWriter {

    /// What the writer decided to do with a file, once it is closed and complete.
    public typealias Outcome = Result<URL, Error>
    
    /// Explicit override, or `nil` to read ``RailtracksSwift/eventsOutputDirectory`` at first
    /// write. Resolved late — not in `init` — so an app (or a test) can configure the global
    /// after constructing the writer, matching how `RTSFlowGraphCollector` reads
    /// `flowGraphOutputDirectory` only when it writes.
    private let configuredDirectory: URL?
    private let queue: Queue
    private let encoder: JSONEncoder

    /// Open append handles, keyed by `scope_id`. One entry in practice — a writer subscribed to
    /// one flow sees one scope — but keyed anyway, because nothing stops an app from pointing
    /// one writer at several flows.
    private var handles: [String: FileHandle] = [:]
    /// Scope ids the path guard already rejected, so a bad id is diagnosed once rather than
    /// once per event.
    private var rejectedScopeIDs: Set<String> = []
    /// The file each scope writes to, kept after a close so a second run on the same flow
    /// reopens the same path in append mode.
    private var fileURLs: [String: URL] = [:]
    /// The first file opened, reported by ``finish()``.
    private var firstFileURL: URL?
    /// Broadcasts each file as it is closed. Mutated only from actor-isolated methods, so the
    /// sends are serialized; `nonisolated(unsafe)` because `CurrentValueSubject` is not
    /// `Sendable` and the publisher has to be reachable without an `await`.
    private nonisolated(unsafe)
    let fileURLSubject: CurrentValueSubject<Outcome?, Never> = .init(nil)
    private var consumerTask: Task<Void, Never>?
    private var isFinished = false
    /// Set after a write fails. The consumer keeps draining so `finish()` still returns, but it
    /// stops attempting I/O — a broken handle does not heal mid-run, and retrying per event
    /// would turn one failure into one log line per remaining event.
    private var hasWriteFailed = false
    private var failure: Error?
    private var writtenLineCount = 0
    private var unencodableEventCount = 0
    /// Scopes whose file has been closed by `session.completed`. An event arriving for one of
    /// these either starts a new run or breaks the invariant — see ``noteArrival(of:)``.
    private var closedScopeIDs: Set<String> = []
    private var lateArrivalCount = 0

    /// - Parameters:
    ///   - directory: Where to write. Defaults to ``RailtracksSwift/eventsOutputDirectory``,
    ///     read at first write rather than here.
    ///   - queueCapacity: How many events may sit between the publisher and the file before the
    ///     oldest are dropped. Matches the Python observer's per-writer bound. Note this bounds
    ///     an event *count*, not bytes — an `llm.invocation` payload carries a whole serialized
    ///     message history, so the memory behind a full queue is not small.
    public init(
        directory: URL? = nil,
        queueCapacity: Int = 10_000
    ) {
        self.configuredDirectory = directory
        self.queue = Queue(capacity: queueCapacity)
        self.encoder = RTSEventWriter.makeEncoder()
    }

    /// Publishes each JSONL file as it is closed — once per run, when `session.completed` is
    /// written, and again from ``finish()`` for a file left open by a run that never completed.
    ///
    /// Deliberately the same shape as `RTSFlow.outputFileURLPublisher`: `CurrentValueSubject`
    /// backed, so a late subscriber still sees the most recent result, with the initial `nil`
    /// filtered out. This is the signal to wait on if you want the file *without* tearing the
    /// writer down — anyone can subscribe, not just whoever calls ``finish()``.
    public nonisolated var fileURLPublisher: AnyPublisher<Outcome, Never> {
        fileURLSubject
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }

    // MARK: - Subscribing

    /// Starts consuming `publisher`. Call once, before the flow runs.
    ///
    /// `nonisolated` so it can be called synchronously at the point the flow is constructed,
    /// without an `await` and without hopping onto the actor.
    ///
    /// - Important: the sink captures only the queue — never `self` — and does nothing but
    ///   enqueue. `RTSEventEmitter.emit` delivers to its subscribers **synchronously, on the
    ///   invoking thread, while holding a non-reentrant lock**, so anything slower than a
    ///   buffer append here would stall the node invocation that published the event, and
    ///   anything that emitted would deadlock. All file I/O happens on the consumer task
    ///   instead. Same structure, and the same reason, as `RTSFlowGraphCollector`.
    public nonisolated func subscribe(to publisher: AnyPublisher<RTSEvent, Never>) {
        let cancellable = publisher.sink { [queue] event in
            queue.enqueue(event)
        }
        // The queue owns the subscription because `AnyCancellable` is not `Sendable` and this
        // method is `nonisolated`; the queue is already `@unchecked Sendable` behind a lock, so
        // it is the one place that can hold it without an unchecked claim of its own.
        guard queue.attach(cancellable) else {
            cancellable.cancel()
            log.warning(
                "⚠️📮 RTSEventWriter is already subscribed or finished, ignoring this publisher"
            )
            return
        }
        Task {
            await self.startConsuming()
        }
    }

    private func startConsuming() {
        guard !isFinished, consumerTask == nil else {
            return
        }
        consumerTask = Task { [weak self] in
            await self?.consume()
        }
    }

    // MARK: - Finishing

    /// Stops consuming, waits for every event already published to reach the file, and closes it.
    ///
    /// This is the drain barrier — the file is complete and safe to read once this returns.
    /// It does not *flush*: writes are unbuffered and land as the consumer processes them, so
    /// what this waits for is the queue emptying, not a buffer emerging.
    ///
    /// - Important: **a writer is one-shot.** This cancels the subscription and terminates the
    ///   queue for good; events published afterwards are discarded, and re-subscribing is
    ///   refused. Call it once, when the flow is done with — not after each run. Idempotent:
    ///   later calls return the same outcome without repeating the work.
    ///
    /// - Returns: the file that was written, or `nil` when no event ever arrived so no file was
    ///   created. `.failure` carries the write error, with the attempted path.
    @discardableResult
    public func finish() async -> Outcome? {
        guard !isFinished else {
            return currentOutcome()
        }
        isFinished = true

        // Cancels the subscription first, then terminates the stream. `finish()` on the
        // continuation is terminal *state* rather than an element, so — unlike Python's
        // `_EndOfStream` sentinel — the buffering policy cannot evict it, and everything already
        // buffered is still delivered before the consumer's loop ends. That is what makes
        // awaiting the task a real barrier rather than a hope.
        queue.finish()
        // `subscribe` starts the consumer through a task hop, so a caller that subscribes and
        // finishes in quick succession can arrive here before that hop ran — leaving a full
        // buffer and no one to drain it. Starting it now is safe and sufficient: the stream is
        // already terminated, so the loop drains what is buffered and then ends.
        if consumerTask == nil {
            consumerTask = Task { [weak self] in
                await self?.consume()
            }
        }
        await consumerTask?.value
        consumerTask = nil

        closeHandles()
        reportLosses()
        return currentOutcome()
    }

    private func consume() async {
        for await event in queue.stream {
            write(event)
        }
    }

    // MARK: - Writing

    private func write(_ event: RTSEvent) {
        guard !hasWriteFailed else {
            return
        }
        noteArrival(of: event)
        let line: Data
        do {
            var encoded = try encoder.encode(event)
            encoded.append(0x0A)
            line = encoded
        } catch {
            // Only reachable for a value `JSONEncoder` refuses outright. Losing one line beats
            // losing the rest of the log, so this is counted and skipped rather than fatal.
            unencodableEventCount += 1
            log.warning(
                "⚠️📮 unable to encode event: \(event.eventType)-\(event.scopeType)-\(event.scopeID)"
            )
            return
        }
        do {
            let handle = try handle(for: event.scopeID)
            try handle.write(contentsOf: line)
            writtenLineCount += 1
        } catch {
            hasWriteFailed = true
            failure = error
            log.warning("⚠️📮 event writer stopped after a write failure: \(error)")
            // Announced here, not at close: a failure to *open* leaves no handle for
            // `closeScope` to sweep, so this is a subscriber's only notice that the log is
            // broken. Reported once — `hasWriteFailed` short-circuits every later event.
            fileURLSubject.send(.failure(error))
            return
        }
        if event.eventType == RTSSessionCompletedEvent.eventTypeName {
            // The run's terminal event, and the last one it emits — `RTSFlow.run` publishes it
            // after the root node's `node.destruction`, so closing on the destruction instead
            // would truncate the file by exactly the event that says how the run ended.
            //
            // Closing here rather than waiting for `finish()` mirrors the Python engine, whose
            // `_call.py` drains and shuts its writers down in the `finally` of every top-level
            // call. The subscription stays live, so a second run on the same flow reopens this
            // same path in append mode.
            closeScope(event.scopeID)
        }
    }

    /// Flags an event that arrives for a scope whose file `session.completed` already closed.
    ///
    /// A new run is the legitimate case — its `session.started` reopens the file in append
    /// mode — and passes silently. Anything else means an event outlived its own run's terminal
    /// marker, so the file was published as complete and is now growing behind a consumer that
    /// may already have read or uploaded it.
    ///
    /// That should be impossible today: every emit site is synchronous within `RTSFlow.run`,
    /// and `session.completed` is the last statement it executes. The check exists because that
    /// invariant is maintained in `RTSFlow` and `RTSNodeInvoker` rather than here — the design
    /// doc records that it has already had to be defended once, when fire-and-forget `llm.*`
    /// reconstruction was rejected for exactly this reason. Draining the queue before closing
    /// would not catch this: a late event is late relative to any drain point.
    ///
    /// Warns once per close, by dropping the scope on the way through: the file is being
    /// reopened, so it is no longer closed. Log, never throw.
    private func noteArrival(of event: RTSEvent) {
        guard closedScopeIDs.remove(event.scopeID) != nil else {
            return
        }
        guard event.eventType != RTSSessionStartedEvent.eventTypeName else {
            return
        }
        lateArrivalCount += 1
        log.warning(
            """
            ⚠️📮 \(event.eventType) arrived after session.completed closed the log for scope \
            \(event.scopeID) — the file was already published as complete and is now being \
            appended to. An emit site is outliving its run.
            """
        )
    }

    /// The append handle for `scopeID`, opened on first sighting.
    ///
    /// `FileHandle.write(contentsOf:)` is an unbuffered `write(2)`, so this is Python's
    /// `handle.flush()`-per-line for free, with no flush call to forget. That per-line
    /// durability is deliberate: it lets a reader tail the file while a run is in progress. The
    /// cost is that such a reader can observe a torn final line, which is exactly what the
    /// Python visualizer's `read_json(..., ignore_errors=True)` compensates for — do not
    /// "fix" it by adding buffering.
    private func handle(for scopeID: String) throws -> FileHandle {
        if let cached = handles[scopeID] {
            return cached
        }
        guard !rejectedScopeIDs.contains(scopeID) else {
            throw RTSError.writeFileFailed("scope_id previously rejected: \(scopeID)")
        }
        let directory = configuredDirectory ?? RailtracksSwift.eventsOutputDirectory
        let fileName = try safeFileName(for: scopeID)
        let url = directory
            .appendingPathComponent(fileName)
            .appendingPathExtension("jsonl")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                // `FileHandle(forWritingTo:)` requires the file to exist — a real difference
                // from Python's `open(..., "a")`, which creates it.
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: url)
            // Append: a second run on the same flow reopens the file this scope already has.
            try opened.seekToEnd()
            handles[scopeID] = opened
            fileURLs[scopeID] = url
            if firstFileURL == nil {
                firstFileURL = url
            }
            return opened
        } catch {
            throw RTSError.writeFileFailed(url.path)
        }
    }

    /// Rejects a `scope_id` that would escape the output directory or name an unopenable file.
    ///
    /// A port of Python's `_check_safe_scope_id`, and like it this runs **before** any file is
    /// created, so a bad id leaves nothing behind. Today `scope_id` is always a flow's UUID
    /// string and cannot trip this — it is kept because the type is public, because
    /// `URL.appendingPathComponent` does not neutralise `..`, and because a future scope id may
    /// not be machine-generated.
    private func safeFileName(for scopeID: String) throws -> String {
        let isUnsafe = scopeID.isEmpty
            || scopeID.hasPrefix(".")
            || scopeID.contains(where: { RTSEventWriter.unsafeScopeIDCharacters.contains($0) })
            // Not in Python: most filesystems cap a component at 255 bytes, and exceeding it
            // fails `open` with an errno that says nothing about why.
            || scopeID.utf8.count > 200
        guard !isUnsafe else {
            rejectedScopeIDs.insert(scopeID)
            log.warning(
                "⚠️📮 unsafe scope_id for the event writer, refusing to open a file: \(scopeID)"
            )
            throw RTSError.writeFileFailed("unsafe scope_id: \(scopeID)")
        }
        return scopeID
    }

    /// `.` and `..` are covered by the leading-dot check.
    private static let unsafeScopeIDCharacters: Set<Character> = ["/", "\\", "\0"]

    // MARK: - Teardown and reporting

    /// Closes one scope's file and publishes it. A no-op when the scope has already been closed
    /// — the ordinary case at ``finish()`` time, since `session.completed` closed it already.
    private func closeScope(_ scopeID: String) {
        guard let handle = handles.removeValue(forKey: scopeID) else {
            return
        }
        closedScopeIDs.insert(scopeID)
        do {
            try handle.close()
        } catch {
            log.warning("⚠️📮 event writer failed to close a file: \(error)")
        }
        guard let url = fileURLs[scopeID] else {
            return
        }
        // A file swept up by `finish()` after a write failure is not a complete log, so it must
        // not be announced as one — the publisher and ``finish()``'s return value have to agree.
        // The failure itself was already published when it happened, so this stays silent.
        guard failure == nil else {
            return
        }
        fileURLSubject.send(.success(url))
    }

    /// Closes whatever is still open — a run that never emitted `session.completed`, or a
    /// writer torn down mid-run.
    private func closeHandles() {
        for scopeID in handles.keys {
            closeScope(scopeID)
        }
    }

    private func reportLosses() {
        let droppedCount = queue.droppedCount
        guard droppedCount > 0 || unencodableEventCount > 0 || lateArrivalCount > 0 else {
            return
        }
        log.warning(
            """
            ⚠️📮 event log incomplete: \(droppedCount) events dropped by a full queue, \
            \(unencodableEventCount) unencodable, \(lateArrivalCount) arrived after their \
            run's session.completed
            """
        )
    }

    private func currentOutcome() -> Outcome? {
        if let failure {
            return .failure(failure)
        }
        guard let url = firstFileURL else {
            return nil
        }
        return .success(url)
    }

    /// Lines actually written. Exposed for diagnostics and tests, not part of the contract.
    public var lineCount: Int {
        writtenLineCount
    }

    /// Events that arrived for a scope after `session.completed` had closed its file, excluding
    /// the `session.started` of a legitimate new run. Non-zero means an emit site outlived its
    /// run and a file grew after being published as complete — see ``noteArrival(of:)``.
    public var lateEventCount: Int {
        lateArrivalCount
    }

    /// Events the queue discarded because it was full.
    public var droppedEventCount: Int {
        queue.droppedCount
    }
}

// MARK: - Encoding

private extension RTSEventWriter {

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Deliberately NOT `.prettyPrinted`: JSONL is one object per line. Both
        // `RTSFlowGraphCollector` and `RTSEvaluation` turn it on under `#if DEBUG`, and copying
        // that habit here would corrupt the format in exactly the builds the tests run in.
        // Without it the encoder emits no literal newline — newlines inside strings are escaped
        // as `\n` — so one `encode` is structurally one line.
        //
        // `.sortedKeys` because Swift's `Dictionary` iteration order is randomized per process:
        // Python's insertion order is unreproducible here, so determinism (diffable files,
        // byte-exact assertions) is the achievable property and worth more.
        //
        // `.withoutEscapingSlashes` to match `json.dumps`, which leaves `/` alone; without it a
        // URL in a payload serializes as `https:\/\/…` and diverges byte-for-byte.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `RTSValue.number` is a `Double`, so a NaN or infinity reaching `latency`,
        // `total_cost` or `duration_seconds` would throw under the default `.throw` strategy
        // and cost the whole event. A quoted token survives the line and degrades to `NULL`
        // under the Python reader's `TRY_CAST`. Python's `json.dumps` emits a bare `NaN`, which
        // is not valid JSON — this is the closest analogue that still parses.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        // No `dateEncodingStrategy`: `RTSEvent.encode(to:)` writes `stamp` itself through
        // `RTSEventTimestamp.isoString(from:)`, so setting one here would be inert and would
        // wrongly imply the encoder governs the wire format.
        return encoder
    }
}

// MARK: - Queue

/// The bounded hand-off between the publisher's thread and the writer's consumer task.
///
/// Separate from the actor because `enqueue` runs on the invoking thread inside the emitter's
/// lock and must not hop, suspend, or touch actor state.
private final class Queue: @unchecked Sendable {

    let stream: AsyncStream<RTSEvent>
    private let continuation: AsyncStream<RTSEvent>.Continuation
    private let lock = NSLock()
    private var drops = 0
    private var nextLogThreshold = 1
    /// Held here rather than on the actor: `AnyCancellable` is not `Sendable`, and `subscribe`
    /// is `nonisolated`, so this lock-guarded class is the honest place to keep it.
    private var subscription: AnyCancellable?
    private var isFinished = false

    init(capacity: Int) {
        (self.stream, self.continuation) = AsyncStream<RTSEvent>.makeStream(
            of: RTSEvent.self,
            // `.bufferingNewest` keeps the newest `capacity` and evicts the **oldest** to make
            // room — Python's `QueuePolicy.DROP_OLDEST`, natively, with the drop reported back
            // through the yield result.
            bufferingPolicy: .bufferingNewest(capacity)
        )
    }

    /// Buffers `event`, evicting the oldest if the queue is full.
    ///
    /// - Important: called synchronously from the Combine sink while `RTSEventEmitter`'s lock
    ///   is held. Never blocks, never suspends, never re-enters the emitter.
    func enqueue(_ event: RTSEvent) {
        // The associated value of `.dropped` is the *evicted oldest* element, not the one just
        // yielded — a natural misreading, and the reason only the count is used here.
        // `.terminated` means `finish()` already ran; ignore it silently.
        guard case .dropped = continuation.yield(event) else {
            return
        }
        recordDrop()
    }

    /// Takes ownership of the sink's cancellable. Returns false if this queue is already
    /// subscribed or already finished, leaving the caller to cancel it.
    func attach(_ cancellable: AnyCancellable) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !isFinished, subscription == nil else {
            return false
        }
        subscription = cancellable
        return true
    }

    func finish() {
        lock.lock()
        isFinished = true
        let attached = subscription
        subscription = nil
        lock.unlock()
        // Cancelled before the stream is terminated, so nothing is yielded into a stream that
        // is about to stop accepting.
        attached?.cancel()
        continuation.finish()
    }

    var droppedCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return drops
    }

    /// Logs at 1, 10, 100 … rather than on every drop, unlike Python's observer.
    ///
    /// This runs on the invocation's thread with the emitter's lock held, so a log line per drop
    /// would serialize every node in the flow behind stderr at precisely the moment the queue is
    /// already saturated. Every drop is still counted; only the reporting is throttled, and
    /// `finish()` always logs the final total.
    private func recordDrop() {
        lock.lock()
        drops += 1
        let total = drops
        let shouldLog = total >= nextLogThreshold
        if shouldLog {
            nextLogThreshold *= 10
        }
        lock.unlock()
        guard shouldLog else {
            return
        }
        log.warning(
            "⚠️📮 event writer queue full, dropped the oldest event (total: \(total))"
        )
    }
}
