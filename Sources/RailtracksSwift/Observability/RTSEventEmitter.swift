//
//  RTSEventEmitter.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Combine
import Foundation

// MARK: - RTSObservedEvent

/// One event on ``RTSEventEmitter/observedEventPublisher``: the typed event, and the run that
/// emitted it.
struct RTSObservedEvent: Sendable {
    let event: RTSInternalEvent
    /// ``RTSEventEmitter/currentRunScope`` where the event was emitted, or `nil` outside a run.
    let runScope: UUID?
}

// MARK: - RTSEventEmitter

/// Wraps typed observability events in a session-scoped ``RTSEvent`` and publishes them.
///
/// Mirrors the Python engine's `emit` / `publish_event` (`events/send.py`,
/// `observability/publish.py`), including the property that matters most there:
/// **observability must never break execution.** Nothing here throws, and a failure to
/// build a payload degrades to `null` rather than propagating.
///
/// **Delivery is isolated from execution.** One emitter is shared by every node in a flow, and
/// `PassthroughSubject.send` runs its subscribers' sinks synchronously on the calling thread —
/// so publishing inline would put arbitrary subscriber code on the invocation's critical path.
/// Worse, serializing that with a lock (the previous design) held the lock *across* the sinks,
/// so one slow subscriber blocked every other node's `emit` and stalled the whole flow.
///
/// Instead, `emit` builds the envelope and hands it to ``deliveryQueue``. The invoking thread
/// does bounded work and returns; the send, and every subscriber's sink, runs on that queue.
/// Nothing a subscriber does can slow a run down.
///
/// Subscribers on this queue share it, so each must do only bounded work. The library's own do:
/// the trace collector, the node status mapper and the event writer. App subscribers never run
/// here: `RTSFlow.eventPublisher` moves them to a queue of their own, so a slow one can't delay
/// the trace, the statuses or the signposts.
///
/// The queue is **serial**, so events reach subscribers in the order they were emitted — this
/// is deliberately not a concurrent queue and deliberately not a `Task` per event, which is
/// the ordering bug `docs/duplicate-node-id.md` records. It also replaces the lock outright:
/// serialization is what the lock was for, so `subject.send` and ``announcedMiddleware`` are
/// now confined to the queue rather than guarded by one.
final class RTSEventEmitter: @unchecked Sendable {

    /// The run whose events are being emitted on this task: `RTSFlow.run` binds a fresh one around
    /// its root invocation, and every event of the run is emitted inside that task tree. `nil`
    /// outside a run, as for `session.*`. Read by ``emit(_:)`` and carried on the typed tap, so
    /// one run's trace collector can ignore another run's events on the same flow.
    @TaskLocal static var currentRunScope: UUID?

    /// The enclosing session's identifier, used as every envelope's `scope_id`.
    private let sessionID: String
    /// When false, nothing reaches the public stream: ``emit(_:)`` builds no envelope. The internal
    /// stream still gets every event. See the note on cost below.
    ///
    /// Readable so a caller can skip work it would only feed to the public stream. `emit`
    /// skipping the envelope is not enough on its own: computing an event's *arguments* can cost
    /// more than the event, and that happens before `emit` is reached.
    let isEnabled: Bool
    private let subject = PassthroughSubject<RTSEvent, Never>()
    /// The internal stream: every event, typed, before encoding, plus the internal-only ones. A
    /// public event is sent in the same queue block as its envelope, so the two streams have the
    /// same order.
    private let observedSubject = PassthroughSubject<RTSObservedEvent, Never>()
    /// Serial, so delivery order matches emission order. Every `subject.send` and every
    /// access to ``announcedMiddleware`` happens here and nowhere else.
    private let deliveryQueue = DispatchQueue(label: "ai.railtown.railtracks.events")
    /// Middleware type ids already announced, so `middleware.creation` fires once per
    /// definition rather than once per invocation — matching Python's `_has_registered`
    /// guard in `middleware/core.py`. Confined to ``deliveryQueue``.
    private var announcedMiddleware: Set<String> = []

    init(
        sessionID: String,
        isEnabled: Bool
    ) {
        self.sessionID = sessionID
        self.isEnabled = isEnabled
    }

    var eventPublisher: AnyPublisher<RTSEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    /// The internal stream, for the trace collector and the node statuses. Internal: unlike
    /// ``eventPublisher``, it keeps what the wire encoding drops, full messages and Swift's
    /// provider names among them, and the events' internal properties. It also carries the events
    /// with no wire form (``RTSInternalEvent``), and it is fed whether or not the emitter is
    /// enabled.
    ///
    /// Delivered on the emitter's queue, so a subscriber's sink must do only bounded work, as
    /// the collector's does by yielding into its stream.
    var observedEventPublisher: AnyPublisher<RTSObservedEvent, Never> {
        observedSubject.eraseToAnyPublisher()
    }

    /// Publishes `event` on the internal stream and, when enabled, wraps it in a session-scoped
    /// envelope for the public one.
    ///
    /// The internal stream gets every event, enabled or not: node statuses are built from it, and
    /// they work with events off. Passing a typed event along costs next to nothing. The envelope
    /// is what costs, since `encodePayload()` JSON-encodes message histories, so the disabled
    /// check comes **before** it, and a flow with events turned off never builds one.
    ///
    /// The envelope is built here, on the calling thread, so `stamp` records when the event
    /// *happened* rather than when it was delivered. Only the send is deferred.
    ///
    /// - Note: delivery is asynchronous, so an event is not necessarily in a subscriber's
    ///   hands when this returns. Use ``flushDelivery()`` where that matters.
    func emit(_ event: some RTSObservabilityEvent) {
        let envelope = isEnabled ? RTSEvent.session(event, sessionID: sessionID) : nil
        // The scope is read here, on the emitting task: the queue has no task-locals.
        let observed = RTSObservedEvent(
            event: .observability(event),
            runScope: RTSEventEmitter.currentRunScope
        )
        deliveryQueue.async { [self] in
            if let envelope {
                subject.send(envelope)
            }
            observedSubject.send(observed)
        }
    }

    /// Publishes a node's executing signal on the internal stream only. It has no wire form, so
    /// it never reaches the public stream, enabled or not.
    func emitNodeExecuting(_ signal: RTSNodeExecutingSignal) {
        let observed = RTSObservedEvent(
            event: .nodeExecuting(signal),
            runScope: RTSEventEmitter.currentRunScope
        )
        deliveryQueue.async { [self] in
            observedSubject.send(observed)
        }
    }

    /// Publishes `middleware.creation` the first time a given middleware definition is seen
    /// in this session, and does nothing on later calls.
    ///
    /// The envelope is built up front even though the dedupe may discard it, so its `stamp`
    /// is the sighting instant rather than the queue's. A rail is announced once per session,
    /// so the wasted build is bounded and rare.
    func emitMiddlewareCreationOnce(
        typeID: String,
        name: String
    ) {
        let event = RTSMiddlewareCreationEvent(
            middlewareTypeID: typeID,
            middlewareName: name
        )
        let envelope = isEnabled ? RTSEvent.session(event, sessionID: sessionID) : nil
        let observed = RTSObservedEvent(
            event: .observability(event),
            runScope: RTSEventEmitter.currentRunScope
        )
        deliveryQueue.async { [self] in
            // Reading and writing the set on the queue is what makes it safe without a lock,
            // and keeps the dedupe ordered against the sends it gates.
            guard announcedMiddleware.insert(typeID).inserted else {
                return
            }
            if let envelope {
                subject.send(envelope)
            }
            observedSubject.send(observed)
        }
    }

    /// Blocks until every event emitted before this call has been handed to subscribers.
    ///
    /// A barrier on the serial delivery queue: work enqueued earlier runs first, so when this
    /// returns the backlog is drained. Needed because ``emit(_:)`` is fire-and-forget — a
    /// caller tearing a subscriber down right after a run would otherwise cut off the tail of
    /// the stream, including `session.completed`.
    /// Suspends rather than blocking: a `sync` barrier here would tie up a cooperative thread
    /// for as long as the backlog takes, and every caller is already in an async context.
    func flushDelivery() async {
        await withCheckedContinuation { continuation in
            deliveryQueue.async {
                continuation.resume()
            }
        }
    }
}
