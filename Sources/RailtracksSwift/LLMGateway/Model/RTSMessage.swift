//
//  RTSMessage.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-07.
//

import Foundation
import Conduit

// MARK: - RTSMessage

public struct RTSMessage: Sendable, Codable {
    public let id: UUID
    public let role: Role
    public let content: Content
    public let timestamp: Date
    public let metadata: RTSMessageMetadata?
    public let runID: RTSRunID?
}

// MARK: - RTSMessage.Role

extension RTSMessage {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }
}

// MARK: - RTSMessage.Content

extension RTSMessage {
    public enum Content: Sendable, Codable {
        case text(String)
        case parts([ContentPart])

        public var textValue: String {
            switch self {
            case .text(let string): return string
            case .parts(let parts):
                return parts.compactMap {
                    if case .text(let t) = $0 { return t }
                    return nil
                }.joined(separator: "\n")
            }
        }

        private enum CodingKeys: String, CodingKey { case type, text, parts }
        private enum ContentType: String, Codable { case text, parts }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(ContentType.self, forKey: .type) {
            case .text:  self = .text(try container.decode(String.self, forKey: .text))
            case .parts: self = .parts(try container.decode([ContentPart].self, forKey: .parts))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let string):
                try container.encode(ContentType.text, forKey: .type)
                try container.encode(string, forKey: .text)
            case .parts(let parts):
                try container.encode(ContentType.parts, forKey: .type)
                try container.encode(parts, forKey: .parts)
            }
        }
    }
}

// MARK: - RTSMessage.ContentPart

extension RTSMessage {
    public enum ContentPart: Sendable, Codable {
        case text(String)
        case image(ImageContent)
        case audio(AudioContent)

        private enum CodingKeys: String, CodingKey { case type, text, modality, info, base64Data, format }
        // Image parts are discriminated by the `modality` key (matching Python); text/audio by `type`.
        private enum PartType: String, Codable { case text, audio }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.modality) {
                self = .image(ImageContent(
                    type: try container.decode(String.self, forKey: .type),
                    info: try container.decode(String.self, forKey: .info)
                ))
                return
            }
            switch try container.decode(PartType.self, forKey: .type) {
            case .text:
                self = .text(try container.decode(String.self, forKey: .text))
            case .audio:
                self = .audio(AudioContent(
                    base64Data: try container.decode(String.self, forKey: .base64Data),
                    format: try container.decode(AudioFormat.self, forKey: .format)
                ))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let string):
                try container.encode(PartType.text, forKey: .type)
                try container.encode(string, forKey: .text)
            case .image(let image):
                // Redacted descriptor matching Python: {modality:"image", type, info}. No base64.
                try container.encode("image", forKey: .modality)
                try container.encode(image.type, forKey: .type)
                try container.encode(image.info, forKey: .info)
            case .audio(let audio):
                try container.encode(PartType.audio, forKey: .type)
                try container.encode(audio.base64Data, forKey: .base64Data)
                try container.encode(audio.format, forKey: .format)
            }
        }
    }
}

// MARK: - RTSMessage.ImageContent

extension RTSMessage {
    /// Redacted descriptor for an image attached to a multi-modal message. Matches the Python
    /// run-report schema (`{modality: "image", type, info}`); the base64 bytes are dropped at the
    /// trace boundary and never stored here.
    public struct ImageContent: Sendable, Codable {
        /// Source kind: `"local"`, `"url"`, or `"data_uri"`.
        public let type: String
        /// Source reference: a file path / URL, or `"..."` for redacted in-memory data.
        public let info: String

        public init(type: String, info: String) {
            self.type = type
            self.info = info
        }
    }
}

// MARK: - RTSMessage.AudioFormat

extension RTSMessage {
    /// Audio container formats supported for multi-modal audio messages.
    public enum AudioFormat: String, Sendable, Codable {
        case wav, mp3, aiff, aac, ogg, flac, m4a
    }
}

// MARK: - RTSMessage.AudioContent

extension RTSMessage {
    /// Base64-encoded audio clip attached to a multi-modal message.
    public struct AudioContent: Sendable, Codable {
        public let base64Data: String
        public let format: AudioFormat

        public init(base64Data: String, format: AudioFormat) {
            self.base64Data = base64Data
            self.format = format
        }
    }
}

// MARK: - RTSMessageMetadata

public struct RTSMessageMetadata: Sendable, Codable {
    public let tokenCount: Int?
    public let inputTokenCount: Int?
    public let generationTime: TimeInterval?
    public let model: String?
    public let providerName: String?
    public let tokensPerSecond: Double?
    public let providerExtra: [String: String]?
    public let custom: [String: String]?
    public let toolCalls: [RTSToolCall]?
}

// MARK: - RTSToolCall

public struct RTSToolCall: Sendable, Codable {
    public let id: String
    public let toolName: String
    public let arguments: RTSGeneratedContent
}

// MARK: - Conduit → RTS Mappings

public extension Message {
    func toRTSMessage(runID: RTSRunID? = nil, providerName: String? = nil) -> RTSMessage {
        RTSMessage(
            id: id,
            role: role.toRTSRole,
            content: content.toRTSContent,
            timestamp: timestamp,
            metadata: metadata?.toRTSMetadata(providerName: providerName),
            runID: runID
        )
    }
}

private extension Message.Role {
    var toRTSRole: RTSMessage.Role {
        switch self {
        case .system:    return .system
        case .user:      return .user
        case .assistant: return .assistant
        case .tool:      return .tool
        }
    }
}

private extension Message.Content {
    var toRTSContent: RTSMessage.Content {
        switch self {
        case .text(let string):   return .text(string)
        case .parts(let parts):   return .parts(parts.map { $0.toRTSContentPart })
        }
    }
}

private extension Message.ContentPart {
    var toRTSContentPart: RTSMessage.ContentPart {
        switch self {
        case .text(let string):  return .text(string)
        case .image(let image):  return .image(image.toRTSImageContent)
        case .audio(let audio):  return .audio(audio.toRTSAudioContent)
        }
    }
}

private extension Message.ImageContent {
    var toRTSImageContent: RTSMessage.ImageContent {
        // base64 is dropped at the trace boundary; images are embedded as data URIs at send time,
        // so at the message level they are always `data_uri` with a redacted `info`.
        RTSMessage.ImageContent(type: "data_uri", info: "...")
    }
}

private extension Message.AudioContent {
    var toRTSAudioContent: RTSMessage.AudioContent {
        RTSMessage.AudioContent(base64Data: base64Data, format: format.toRTSAudioFormat)
    }
}

private extension Message.AudioFormat {
    var toRTSAudioFormat: RTSMessage.AudioFormat {
        switch self {
        case .wav:  return .wav
        case .mp3:  return .mp3
        case .aiff: return .aiff
        case .aac:  return .aac
        case .ogg:  return .ogg
        case .flac: return .flac
        case .m4a:  return .m4a
        }
    }
}

private extension MessageMetadata {
    func toRTSMetadata(providerName: String? = nil) -> RTSMessageMetadata {
        RTSMessageMetadata(
            tokenCount: tokenCount,
            inputTokenCount: inputTokenCount,
            generationTime: generationTime,
            model: model,
            providerName: providerName,
            tokensPerSecond: tokensPerSecond,
            providerExtra: providerExtra,
            custom: custom,
            toolCalls: toolCalls?.map { $0.toRTSToolCall }
        )
    }
}

private extension Transcript.ToolCall {
    var toRTSToolCall: RTSToolCall {
        RTSToolCall(id: id, toolName: toolName, arguments: arguments.toRTSGeneratedContent)
    }
}

private extension GeneratedContent {
    var toRTSGeneratedContent: RTSGeneratedContent {
        switch kind {
        case .null:
            return RTSGeneratedContent(kind: .null)
        case .bool(let v):
            return RTSGeneratedContent(kind: .bool(v))
        case .number(let v):
            return RTSGeneratedContent(kind: .number(v))
        case .string(let v):
            return RTSGeneratedContent(kind: .string(v))
        case .array(let elements):
            return RTSGeneratedContent(kind: .array(elements.map { $0.toRTSGeneratedContent }))
        case .structure(let props, _):
            return RTSGeneratedContent(kind: .structure(props.mapValues { $0.toRTSGeneratedContent }))
        }
    }
}

extension RTSGeneratedContent {
    init(kind: Kind) {
        self.kind = kind
    }
}
