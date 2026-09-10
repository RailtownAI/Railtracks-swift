//
//  RTSLLMEvents.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-09-04.
//

import Foundation

// MARK: - RTSEventModelProvider

/// Translates a Swift provider name to the value the Python engine's `model_provider`
/// column expects.
///
/// `events/registry.py` types `model_provider` as an **enum** column over Python's
/// `ModelProvider` members, so an unmapped Swift-only spelling would violate the
/// consumer's schema. Two of the four diverge:
///
/// | `RTSLLMProvider.providerName` | Python `ModelProvider` member | wire value |
/// |---|---|---|
/// | `OpenAI` | `OPENAI` | `OpenAI` |
/// | `Anthropic` | `ANTHROPIC` | `Anthropic` |
/// | `Gemini` | `GEMINI` | `Vertex_AI` |
/// | `AppleAI` | `APPLE_FM` | `apple` |
///
/// **`Vertex_AI` is a misnomer, and it is Python's — both engines share it.** Vertex AI is
/// Google Cloud's platform; the Gemini API on Google AI Studio
/// (`generativelanguage.googleapis.com`) is a separate endpoint. LiteLLM distinguishes them
/// by prefix, and Python's `GeminiLLM.full_model_name` returns `gemini/{model}` — the **AI
/// Studio** route — while still reporting `ModelProvider.GEMINI`, whose value is
/// `"Vertex_AI"`. Conduit's `GeminiProvider` uses that same AI Studio endpoint.
///
/// So mapping to `Vertex_AI` is accurate about *what Python would emit for the same call*,
/// which is what parity requires here. What neither engine can express in this column is
/// the Vertex AI route itself — if a consumer ever needs to tell the two apart, for billing,
/// quota or region, Python's enum needs a new member.
///
/// Note this is the event stream only. The flow-graph JSON keeps emitting Swift's own
/// spelling in `llm_details.model_provider` — the two streams are independent by design,
/// and changing the flow graph would break its existing consumers.
enum RTSEventModelProvider {

    /// The Python `ModelProvider` value for `providerName`, or `"Unknown"` when there is
    /// no mapping — matching Python's own `ModelProvider.UNKNOWN` member rather than
    /// inventing a value the column cannot hold.
    static func wireValue(for providerName: String) -> String {
        switch providerName {
        case "OpenAI":
            return "OpenAI"
        case "Anthropic":
            return "Anthropic"
        case "Gemini":
            return "Vertex_AI"
        case "AppleAI":
            return "apple"
        default:
            return "Unknown"
        }
    }
}

// MARK: - RTSLLMCreationEvent

/// A model was made available for a round trip.
///
/// Mirrors the Python engine's `LLMCreationEvent` (`events/llm.py`). Emitted before the
/// LLM scope is entered, so it carries no ``RTSEventParent`` — the Swift equivalent of
/// Python's `CreationEventBase`.
///
/// Python re-emits this on every `invoke()`, so consumers deduplicate on
/// `(scope_id, llm_id)`.
public struct RTSLLMCreationEvent: RTSObservabilityEvent {
    public var eventType: String {
        "llm.creation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    /// Identifies the model instance, not the round trip. Python's `ModelBase.id`.
    public let llmID: String
    /// Swift's provider name; translated on encode. See ``RTSEventModelProvider``.
    public let modelProvider: String
    public let modelName: String

    public init(
        llmID: String,
        modelProvider: String,
        modelName: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.llmID = llmID
        self.modelProvider = modelProvider
        self.modelName = modelName
        self.spatialParent = .noParent
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = basePayload()
        payload["llm_id"] = .string(llmID)
        payload["model_provider"] = .string(RTSEventModelProvider.wireValue(for: modelProvider))
        payload["model_name"] = .string(modelName)
        return payload
    }
}

// MARK: - RTSLLMInvocationEvent

/// A request is going out to the provider.
///
/// Mirrors the Python engine's `LLMInvocationEvent` (`events/llm.py`). One round trip —
/// **not** an agent's whole tool-calling loop, which produces one of these per iteration.
public struct RTSLLMInvocationEvent: RTSParentedEvent {
    public var eventType: String {
        "llm.invocation"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let messageInput: [RTSMessage]

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageInput: [RTSMessage],
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageInput = messageInput
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["message_input"] = .encodingMessages(messageInput)
        return payload
    }
}

// MARK: - RTSLLMResponseEvent

/// A completed round trip, plus what the provider reported about it.
///
/// Mirrors the Python engine's `LLMResponseEvent` (`events/llm.py`).
public struct RTSLLMResponseEvent: RTSParentedEvent {
    public var eventType: String {
        "llm.response"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let messageInput: [RTSMessage]
    public let output: RTSMessage?
    /// The model name the provider echoed back, which can differ from the one requested.
    public let reportedModelName: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalCost: Double?
    public let systemFingerprint: String?
    public let latency: TimeInterval?

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageInput: [RTSMessage],
        output: RTSMessage?,
        reportedModelName: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalCost: Double? = nil,
        systemFingerprint: String? = nil,
        latency: TimeInterval? = nil,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageInput = messageInput
        self.output = output
        self.reportedModelName = reportedModelName
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalCost = totalCost
        self.systemFingerprint = systemFingerprint
        self.latency = latency
        self.timestamp = timestamp
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload()
        payload["message_input"] = .encodingMessages(messageInput)
        payload["output"] = output.map { RTSValue.encoding($0.toFlowGraphMessage()) } ?? .null
        payload["reported_model_name"] = .nullable(reportedModelName)
        payload["input_tokens"] = .nullable(inputTokens)
        payload["output_tokens"] = .nullable(outputTokens)
        payload["total_cost"] = .nullable(totalCost)
        payload["system_fingerprint"] = .nullable(systemFingerprint)
        payload["latency"] = .nullable(latency)
        return payload
    }
}

// MARK: - RTSLLMFailureEvent

/// A round trip that threw.
///
/// Mirrors the Python engine's `LLMFailureEvent` (`events/llm.py`), which composes
/// `FailureMixin` — ``RTSFailureReporting`` here.
public struct RTSLLMFailureEvent: RTSParentedEvent, RTSFailureReporting {
    public var eventType: String {
        "llm.failure"
    }

    public let timestamp: Date
    public let spatialParent: RTSEventSpatialParent
    public let parent: RTSEventParent
    public let messageInput: [RTSMessage]
    public let exceptionName: String
    public let exceptionMessage: String

    public init(
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageInput: [RTSMessage],
        exceptionName: String,
        exceptionMessage: String,
        timestamp: Date = RTSEventTimestamp.now()
    ) {
        self.parent = parent
        self.spatialParent = spatialParent
        self.messageInput = messageInput
        self.exceptionName = exceptionName
        self.exceptionMessage = exceptionMessage
        self.timestamp = timestamp
    }

    /// Builds the event from a thrown error, mirroring Python's `FailureMixin.from_exception`.
    public static func from(
        error: Error,
        parent: RTSEventParent,
        spatialParent: RTSEventSpatialParent,
        messageInput: [RTSMessage],
        timestamp: Date = RTSEventTimestamp.now()
    ) -> RTSLLMFailureEvent {
        let failure = RTSEventFailure.fields(from: error)
        return RTSLLMFailureEvent(
            parent: parent,
            spatialParent: spatialParent,
            messageInput: messageInput,
            exceptionName: failure.name,
            exceptionMessage: failure.message,
            timestamp: timestamp
        )
    }

    public func encodePayload() -> [String: RTSValue] {
        var payload = parentedBasePayload().merging(failurePayloadFields()) { _, new in new }
        payload["message_input"] = .encodingMessages(messageInput)
        return payload
    }
}

// MARK: - Message encoding

extension RTSValue {
    /// Encodes a message history as the `{role, content}` array the visualizer consumes.
    ///
    /// Reuses `RTSMessage.toFlowGraphMessage()` — the same converter the flow-graph parser
    /// uses — so the two streams cannot drift apart on message shape.
    static func encodingMessages(_ messages: [RTSMessage]) -> RTSValue {
        .array(messages.map { RTSValue.encoding($0.toFlowGraphMessage()) })
    }
}
