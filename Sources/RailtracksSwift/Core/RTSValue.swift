//
//  RTSValue.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-01.
//

import Foundation

/// Named dictionary of keyed inputs passed into a node before invocation.
public typealias RTSInput  = [String: RTSValue]
/// Named dictionary of keyed outputs returned by a node after invocation.
public typealias RTSOutput = [String: RTSValue]

public enum RTSValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RTSValue])
    case object([String: RTSValue])
    /// A multimodal image input. Encodes as a redacted `{modality, type, info}` descriptor — the
    /// base64 payload is held in memory only and never serialized into the trace. Not produced on
    /// decode (a serialized descriptor round-trips back as `.object`, which no consumer reads).
    case image(RTSImage)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([RTSValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: RTSValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                RTSValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
          switch self {
          case .null:
              var container = encoder.singleValueContainer()
              try container.encodeNil()
          case .bool(let v):
              var container = encoder.singleValueContainer()
              try container.encode(v)
          case .number(let v):
              var container = encoder.singleValueContainer()
              try container.encode(v)
          case .string(let v):
              var container = encoder.singleValueContainer()
              try container.encode(v)
          case .array(let elements):
              var container = encoder.unkeyedContainer()
              for element in elements {
                  try container.encode(element)
              }
          case .object(let dict):
              var container = encoder.container(keyedBy: AnyCodingKey.self)
              for (key, value) in dict {
                  try container.encode(value, forKey: AnyCodingKey(key))
              }
          case .image(let image):
              // Redacted descriptor matching the Python run-report schema; base64 is never serialized.
              var container = encoder.container(keyedBy: AnyCodingKey.self)
              try container.encode("image", forKey: AnyCodingKey("modality"))
              try container.encode(image.sourceType, forKey: AnyCodingKey("type"))
              try container.encode(image.sourceInfo, forKey: AnyCodingKey("info"))
          }
      }
                      
      private struct AnyCodingKey: CodingKey {
          let stringValue: String
          var intValue: Int? {
              nil
          }
          
          init(_ string: String) {
              self.stringValue = string
          }
          
          init?(stringValue: String) {
              self.stringValue = stringValue
          }
          
          init?(intValue: Int) {
              nil
          }
      }
}

/// Value type used for tool parameter schema
public indirect enum RTSValueType: Sendable {
    case string
    case number
    case bool
    case array(RTSValueType)
}
