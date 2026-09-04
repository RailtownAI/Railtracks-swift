//
//  RTSMiddlewareEvents.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// The Python engine's `middleware.*` family, ported in full (`events/middleware.py`).
//
// Middleware there is a *general* interception abstraction — `Middleware.wrap(_:)` composes
// a callable around either any node call ("regular" / node band) or any raw model round trip
// ("model" band). Guardrails are one of roughly seven kinds; the others are `Retry`,
// `Timeout`, `Lock`, `MaxCalls`, `ContextInjection`, and the pre/post verifiers.
//
// Swift has **no middleware layer**. Guardrails run directly in `RTSNodeInvoker.invokeAgent`
// via `RTSGuardrailRunner`, so only ``RTSMiddlewareCreationEvent`` and the six
// `middleware.guard.*` events have a Swift emit site today. The other fourteen are defined
// anyway: an incomplete union is a latent breaking change, and every field they need is a
// `JSON` column in the Python registry, so nothing has to be invented to declare them. Each
// one names its Python emitter below.
//
// A note on granularity that applies to every guard event here: Python's guardrails are
// *model* middleware and run once per provider round trip, so an agent making three round
// trips runs its guards three times. Swift's run once per node invocation, wrapping all
// round trips together — Conduit owns the tool-calling loop inside `ChatSession.send`, so a
// node-level guard is the only interception point Swift has. That is a deliberate design
// choice, not a gap, and it is why Swift's guard events carry a
// ``RTSEventSpatialParent/nodeAndMiddleware(nodeID:middlewareInvokeID:)`` rather than
// Python's `llmAndMiddleware`.

// MARK: - RTSMiddlewareCreationEvent

/// A middleware definition was registered.
///
/// Mirrors Python's `MiddlewareCreationEvent`, emitted once per `Middleware` instance from
/// `middleware/core.py`.
public struct RTSMiddlewareCreationEvent: RTSObservabilityEvent {
    public var eventType: String {
        "middleware.creation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    /// Identifies the middleware *definition*, shared by every invocation of it.
    public let middlewareTypeID: String
    public let middlewareName: String

    public init(
        middlewareTypeID: String,
        middlewareName: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.middlewareTypeID = middlewareTypeID
        self.middlewareName = middlewareName
        self.spatialParent = .noParent
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = basePayload()
        payload["middleware_type_id"] = .string(middlewareTypeID)
        payload["middleware_name"] = .string(middlewareName)
        return payload
    }
}

// MARK: - RTSMiddlewareEvent

/// Shared surface of every non-creation middleware event: it names the middleware
/// invocation as its ``parent``.
///
/// Mirrors Python's `MiddlewareEventBase`.
public protocol RTSMiddlewareEvent: RTSParentedEvent {
}

// MARK: - Guard input

/// An input guardrail is about to run.
///
/// Mirrors Python's `MiddlewareGuardInputInvocationEvent`, emitted from
/// `guardrails/llm/concrete.py`.
public struct RTSGuardInputInvocationEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.guard.input.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    /// Python carries a `MessageHistory` here. Swift's input guardrails inspect the node's
    /// `RTSInput`, so that is what this carries.
    public let messageHistory: RTSInput

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageHistory: RTSInput,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageHistory = messageHistory
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["message_history"] = .object(messageHistory)
        return payload
    }
}

/// An input guardrail returned a verdict.
///
/// Mirrors Python's `MiddlewareGuardInputResponseEvent`. Note a **block is reported here**,
/// as a ``RTSGuardrailDecision/Action/block`` decision — not as a failure event. The
/// `.failure` variant covers only the guardrail machinery itself throwing.
public struct RTSGuardInputResponseEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.guard.input.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let messageHistory: RTSInput
    public let decision: RTSGuardrailDecision

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageHistory: RTSInput,
        decision: RTSGuardrailDecision,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageHistory = messageHistory
        self.decision = decision
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["message_history"] = .object(messageHistory)
        payload["decision"] = decision.encoded()
        return payload
    }
}

/// An input guardrail's `check` threw.
///
/// Mirrors Python's `MiddlewareGuardInputFailureEvent`.
public struct RTSGuardInputFailureEvent: RTSMiddlewareEvent, RTSFailureReporting {
    public var eventType: String {
        "middleware.guard.input.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    /// Builds the event from a thrown error, mirroring Python's `FailureMixin.from_exception`.
    public static func from(
        error: Error,
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        timestamp: Date = RTSEventTimestamp.now()
    ) -> RTSGuardInputFailureEvent {
        let failure = RTSEventFailure.fields(from: error)
        return RTSGuardInputFailureEvent(
            parent: parent,
            spatialParent: spatialParent,
            exceptionName: failure.name,
            exceptionMessage: failure.message,
            timestamp: timestamp
        )
    }

    public func encodePayload() -> [String: RTSValue] {
        parentedBasePayload().merging(failurePayloadFields()) { _, new in new }
    }
}

// MARK: - Guard output

/// An output guardrail is about to run.
///
/// Mirrors Python's `MiddlewareGuardOutputInvocationEvent`.
public struct RTSGuardOutputInvocationEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.guard.output.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    /// Python carries a `Message` here. Swift's output guardrails inspect the node's
    /// `RTSOutput`, so that is what this carries.
    public let response: RTSOutput

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSOutput,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .object(response)
        return payload
    }
}

/// An output guardrail returned a verdict.
///
/// Mirrors Python's `MiddlewareGuardOutputResponseEvent`. As on the input side, a block is
/// a ``RTSGuardrailDecision/Action/block`` decision here, not a failure event.
public struct RTSGuardOutputResponseEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.guard.output.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSOutput
    public let decision: RTSGuardrailDecision

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSOutput,
        decision: RTSGuardrailDecision,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.decision = decision
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .object(response)
        payload["decision"] = decision.encoded()
        return payload
    }
}

/// An output guardrail's `check` threw.
///
/// Mirrors Python's `MiddlewareGuardOutputFailureEvent`.
public struct RTSGuardOutputFailureEvent: RTSMiddlewareEvent, RTSFailureReporting {
    public var eventType: String {
        "middleware.guard.output.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    /// Builds the event from a thrown error, mirroring Python's `FailureMixin.from_exception`.
    public static func from(
        error: Error,
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        timestamp: Date = RTSEventTimestamp.now()
    ) -> RTSGuardOutputFailureEvent {
        let failure = RTSEventFailure.fields(from: error)
        return RTSGuardOutputFailureEvent(
            parent: parent,
            spatialParent: spatialParent,
            exceptionName: failure.name,
            exceptionMessage: failure.message,
            timestamp: timestamp
        )
    }

    public func encodePayload() -> [String: RTSValue] {
        parentedBasePayload().merging(failurePayloadFields()) { _, new in new }
    }
}

// MARK: - Events with no Swift emit site
//
// Everything below is structure only. Swift has no middleware chain, no `@post_node`, and
// no `@pre_llm` / `@post_llm`, so nothing constructs these yet. They are declared so the
// family is complete and so adding Swift's middleware layer later is additive rather than
// a reshaping of what shipped.

// MARK: Bare middleware triple

/// Any middleware invocation, whole.
///
/// Mirrors Python's `MiddlewareInvocationEvent`, emitted by `middleware/chain.py` for
/// **every** middleware — in addition to whatever specialised events that middleware's own
/// decorator emits. Band-agnostic: the spatial parent may be either node- or model-side.
///
/// No Swift emit site: Swift has no middleware chain. Synthesizing this today would invent
/// structure that does not exist.
public struct RTSMiddlewareInvocationEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let args: [RTSValue]
    public let kwargs: RTSInput

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        args: [RTSValue] = [],
        kwargs: RTSInput,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.args = args
        self.kwargs = kwargs
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["args"] = .array(args)
        payload["kwargs"] = .object(kwargs)
        return payload
    }
}

/// Any middleware invocation's result. Mirrors Python's `MiddlewareResponseEvent`
/// (`middleware/chain.py`). No Swift emit site — see ``RTSMiddlewareInvocationEvent``.
public struct RTSMiddlewareResponseEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        return payload
    }
}

/// Any middleware invocation that threw. Mirrors Python's `MiddlewareFailureEvent`
/// (`middleware/chain.py`). This is also where a guardrail **block** surfaces in Python,
/// as the resulting error unwinds through the chain. No Swift emit site.
public struct RTSMiddlewareFailureEvent: RTSMiddlewareEvent, RTSFailureReporting {
    public var eventType: String {
        "middleware.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        parentedBasePayload().merging(failurePayloadFields()) { _, new in new }
    }
}

// MARK: Model band — `@wrap_llm`

/// A model middleware wrapping one raw round trip. Mirrors Python's
/// `MiddlewareModelInvocationEvent` (`built_nodes/llm/middleware/wrap_llm.py`).
/// No Swift emit site: Conduit owns the round-trip loop.
public struct RTSMiddlewareModelInvocationEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.model.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let messageHistory: [RTSMessage]
    /// The tool definitions offered on this call, as JSON. Note this — not any `llm.*`
    /// event — is where Python records the available tools.
    public let tools: RTSValue?
    /// The structured-output schema requested, as JSON.
    public let schema: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageHistory: [RTSMessage],
        tools: RTSValue?,
        schema: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageHistory = messageHistory
        self.tools = tools
        self.schema = schema
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["message_history"] = .encodingMessages(messageHistory)
        payload["tools"] = .nullable(tools)
        payload["schema"] = .nullable(schema)
        return payload
    }
}

/// Mirrors Python's `MiddlewareModelResponseEvent` (`wrap_llm.py`). No Swift emit site.
public struct RTSMiddlewareModelResponseEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.model.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        return payload
    }
}

/// Mirrors Python's `MiddlewareModelFailureEvent` (`wrap_llm.py`). No Swift emit site.
public struct RTSMiddlewareModelFailureEvent: RTSMiddlewareEvent, RTSFailureReporting {
    public var eventType: String {
        "middleware.model.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        parentedBasePayload().merging(failurePayloadFields()) { _, new in new }
    }
}

// MARK: Model band — `@pre_llm` (request transform)

/// A request transform is about to run. Mirrors Python's
/// `MiddlewareModelInputInvocationEvent` (`built_nodes/llm/middleware/pre_llm.py`).
/// No Swift emit site.
///
/// Note there is deliberately **no `middleware.model.input.failure`** counterpart — Python
/// does not define one, and an exception in the transform is caught one layer out by
/// ``RTSMiddlewareModelFailureEvent``. That asymmetry is copied, not overlooked.
public struct RTSMiddlewareModelInputInvocationEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.model.input.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let messageHistory: [RTSMessage]
    public let tools: RTSValue?
    public let schema: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageHistory: [RTSMessage],
        tools: RTSValue?,
        schema: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageHistory = messageHistory
        self.tools = tools
        self.schema = schema
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["message_history"] = .encodingMessages(messageHistory)
        payload["tools"] = .nullable(tools)
        payload["schema"] = .nullable(schema)
        return payload
    }
}

/// A request transform finished. Mirrors Python's `MiddlewareModelInputResponseEvent`
/// (`pre_llm.py`). No Swift emit site.
public struct RTSMiddlewareModelInputResponseEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.model.input.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let messageHistory: [RTSMessage]
    public let tools: RTSValue?
    public let schema: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageHistory: [RTSMessage],
        tools: RTSValue?,
        schema: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageHistory = messageHistory
        self.tools = tools
        self.schema = schema
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["message_history"] = .encodingMessages(messageHistory)
        payload["tools"] = .nullable(tools)
        payload["schema"] = .nullable(schema)
        return payload
    }
}

// MARK: Model band — `@post_llm` (response transform)

/// A response transform is about to run. Mirrors Python's
/// `MiddlewareModelOutputInvocationEvent` (`built_nodes/llm/middleware/post_llm.py`).
/// No Swift emit site.
public struct RTSMiddlewareModelOutputInvocationEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.model.output.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        return payload
    }
}

/// A response transform finished. Mirrors Python's `MiddlewareModelOutputResponseEvent`
/// (`post_llm.py`). No Swift emit site.
public struct RTSMiddlewareModelOutputResponseEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.model.output.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        return payload
    }
}

/// A response transform threw. Mirrors Python's `MiddlewareModelOutputFailureEvent`
/// (`post_llm.py`). No Swift emit site.
public struct RTSMiddlewareModelOutputFailureEvent: RTSMiddlewareEvent, RTSFailureReporting {
    public var eventType: String {
        "middleware.model.output.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        parentedBasePayload().merging(failurePayloadFields()) { _, new in new }
    }
}

// MARK: Node band — `@post_node`

/// A post-node result hook is about to run. Mirrors Python's
/// `MiddlewareOutputInvocationEvent` (`middleware/post.py`). No Swift emit site.
///
/// "Regular" is Python's name for the node band, as opposed to the model band. Note there
/// is deliberately **no `middleware.regular.input.*`** family — Python has no `@pre_node`.
public struct RTSMiddlewareRegularOutputInvocationEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.regular.output.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        return payload
    }
}

/// A post-node result hook finished. Mirrors Python's `MiddlewareOutputResponseEvent`
/// (`middleware/post.py`). No Swift emit site.
public struct RTSMiddlewareRegularOutputResponseEvent: RTSMiddlewareEvent {
    public var eventType: String {
        "middleware.regular.output.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let response: RTSValue?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        response: RTSValue?,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.response = response
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["response"] = .nullable(response)
        return payload
    }
}

/// Mirrors Python's `MiddlewareOutputFailureEvent` (`middleware/post.py`).
///
/// Emitted by neither engine: `@post_node` has no `try`/`except` around the hook, so Python
/// defines this class but never constructs it. Ported for completeness, and because the
/// Python registry's completeness test covers it.
public struct RTSMiddlewareRegularOutputFailureEvent: RTSMiddlewareEvent, RTSFailureReporting {
    public var eventType: String {
        "middleware.regular.output.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        parentedBasePayload().merging(failurePayloadFields()) { _, new in new }
    }
}
