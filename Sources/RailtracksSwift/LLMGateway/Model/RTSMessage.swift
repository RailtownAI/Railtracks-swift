//
//  RTSMessage.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-07.
//

import Foundation
import ConduitAdvanced

// MARK: - RTSMessage

public struct RTSMessage: Sendable, Codable {
    public let id: UUID
    public let role: Role
    public let content: Content
    public let timestamp: Date
    public let metadata: RTSMessageMetadata?
    public let runID: UUID?
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

        private enum CodingKeys: String, CodingKey { case type, text, base64Data, mimeType, format }
        private enum PartType: String, Codable { case text, image, audio }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(PartType.self, forKey: .type) {
            case .text:
                self = .text(try container.decode(String.self, forKey: .text))
            case .image:
                self = .image(ImageContent(
                    base64Data: try container.decode(String.self, forKey: .base64Data),
                    mimeType: try container.decode(String.self, forKey: .mimeType)
                ))
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
                try container.encode(PartType.image, forKey: .type)
                try container.encode(image.base64Data, forKey: .base64Data)
                try container.encode(image.mimeType, forKey: .mimeType)
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
    public struct ImageContent: Sendable, Codable {
        public let base64Data: String
        public let mimeType: String

        public init(base64Data: String, mimeType: String = "image/jpeg") {
            self.base64Data = base64Data
            self.mimeType = mimeType
        }
    }
}

// MARK: - RTSMessage.AudioFormat

extension RTSMessage {
    public enum AudioFormat: String, Sendable, Codable {
        case wav, mp3, aiff, aac, ogg, flac, m4a
    }
}

// MARK: - RTSMessage.AudioContent

extension RTSMessage {
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
    public let generationTime: TimeInterval?
    public let model: String?
    public let tokensPerSecond: Double?
    public let custom: [String: String]?
    public let toolCalls: [RTSToolCall]?
}

// MARK: - RTSToolCall

public struct RTSToolCall: Sendable, Codable {
    public let id: String
    public let toolName: String
    public let arguments: RTSGeneratedContent
}

// MARK: - RTSGeneratedContent

public struct RTSGeneratedContent: Sendable, Codable {
    public enum Kind: Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([RTSGeneratedContent])
        case structure([String: RTSGeneratedContent])
    }
    public let kind: Kind

    private enum CodingKeys: String, CodingKey { case type, value, elements, properties }
    private enum KindType: String, Codable { case null, bool, number, string, array, structure }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(KindType.self, forKey: .type) {
        case .null:      kind = .null
        case .bool:      kind = .bool(try container.decode(Bool.self, forKey: .value))
        case .number:    kind = .number(try container.decode(Double.self, forKey: .value))
        case .string:    kind = .string(try container.decode(String.self, forKey: .value))
        case .array:     kind = .array(try container.decode([RTSGeneratedContent].self, forKey: .elements))
        case .structure: kind = .structure(try container.decode([String: RTSGeneratedContent].self, forKey: .properties))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .null:
            try container.encode(KindType.null, forKey: .type)
        case .bool(let v):
            try container.encode(KindType.bool, forKey: .type)
            try container.encode(v, forKey: .value)
        case .number(let v):
            try container.encode(KindType.number, forKey: .type)
            try container.encode(v, forKey: .value)
        case .string(let v):
            try container.encode(KindType.string, forKey: .type)
            try container.encode(v, forKey: .value)
        case .array(let elements):
            try container.encode(KindType.array, forKey: .type)
            try container.encode(elements, forKey: .elements)
        case .structure(let props):
            try container.encode(KindType.structure, forKey: .type)
            try container.encode(props, forKey: .properties)
        }
    }
}

// MARK: - Conduit → RTS Mappings

public extension Message {
    func toRTSMessage(runID: UUID? = nil) -> RTSMessage {
        RTSMessage(
            id: id,
            role: role.toRTSRole,
            content: content.toRTSContent,
            timestamp: timestamp,
            metadata: metadata?.toRTSMetadata,
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
        RTSMessage.ImageContent(base64Data: base64Data, mimeType: mimeType)
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
    var toRTSMetadata: RTSMessageMetadata {
        RTSMessageMetadata(
            tokenCount: tokenCount,
            generationTime: generationTime,
            model: model,
            tokensPerSecond: tokensPerSecond,
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

private extension RTSGeneratedContent {
    init(kind: Kind) {
        self.kind = kind
    }
}
