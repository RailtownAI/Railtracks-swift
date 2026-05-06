//
//  RTSValue.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-01.
//

import Foundation

public typealias RTSInput  = [String: RTSValue]
public typealias RTSOutput = [String: RTSValue]

public enum RTSValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RTSValue])
    case object([String: RTSValue])
    
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
}

/// Value type used for tool parameter schema
public enum RTSValueType {
    case string, number, bool
}
