//
//  RTSEventEmitter.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Combine
import Foundation

// MARK: - RTSEventEmitter

/// Wraps typed observability events in a session-scoped ``RTSEvent`` and publishes them.
///
/// Mirrors the Python engine's `emit` / `publish_event` (`events/send.py`,
/// `observability/publish.py`), including the property that matters most there:
/// **observability must never break execution.** Nothing here throws, and a failure to
/// build a payload degrades to `null` rather than propagating.
///
/// Concurrency follows `RTSNodeInvoker`'s established pattern — `@unchecked Sendable`
/// backed by a real `NSLock`, because `PassthroughSubject.send` is not safe under
/// concurrent calls and one emitter is shared by every node in a flow.
final class RTSEventEmitter: @unchecked Sendable {

    /// The enclosing session's identifier, used as every envelope's `scope_id`.
    private let sessionID: String
    /// When false, ``emit(_:)`` returns before building anything. See the note on cost below.
    ///
    /// Readable so a caller can skip work it would only feed to a disabled emitter. `emit`
    /// short-circuiting is not enough on its own: computing an event's *arguments* can cost
    /// more than the event, and that happens before `emit` is reached.
    let isEnabled: Bool
    private let subject = PassthroughSubject<RTSEvent, Never>()
    /// Guards both `subject.send` and `announcedMiddleware`.
    private let publishLock = NSLock()
    /// Middleware type ids already announced, so `middleware.creation` fires once per
    /// definition rather than once per invocation — matching Python's `_has_registered`
    /// guard in `middleware/core.py`.
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

    /// Wraps `event` in a session-scoped envelope and publishes it.
    ///
    /// The disabled check comes **first**, before `encodePayload()`, because building a
    /// payload is not free — it JSON-encodes message histories — and a flow with events
    /// turned off should pay nothing.
    ///
    /// - Important: `PassthroughSubject.send` runs its subscribers' sinks synchronously on
    ///   the calling thread, and this holds a non-reentrant `NSLock` across it. So a sink
    ///   must not re-enter `emit` — directly or transitively — or the thread deadlocks on a
    ///   lock it already owns. Out of reach for an external subscriber today, since `emit` is
    ///   internal and a node invocation is `async`, but any *internal* subscriber that emits
    ///   would hit it. A sink should also stay cheap for the simpler reason that slow work
    ///   inside one blocks the invocation that published the event.
    func emit(_ event: some RTSObservabilityEvent) {
        guard isEnabled else {
            return
        }
        // Built before the lock is taken: `encodePayload()` must not run inside the
        // critical section, and nothing may suspend while the lock is held.
        let envelope = RTSEvent.session(event, sessionID: sessionID)
        publishLock.lock()
        defer {
            publishLock.unlock()
        }
        subject.send(envelope)
    }

    /// Publishes `middleware.creation` the first time a given middleware definition is seen
    /// in this session, and does nothing on later calls.
    func emitMiddlewareCreationOnce(
        typeID: String,
        name: String
    ) {
        guard isEnabled else {
            return
        }
        publishLock.lock()
        let isFirstSighting = announcedMiddleware.insert(typeID).inserted
        publishLock.unlock()
        // Released before emitting: `NSLock` is not recursive, and `emit` takes it again.
        guard isFirstSighting else {
            return
        }
        emit(
            RTSMiddlewareCreationEvent(
                middlewareTypeID: typeID,
                middlewareName: name
            )
        )
    }
}
