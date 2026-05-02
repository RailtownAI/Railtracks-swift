//
//  RTSValue.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-01.
//

import Foundation

public enum RTSValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([RTSValue])
    case object([String: RTSValue])
}

//typealias RTSInput  = [String: RTSValue]
//typealias RTSOutput = [String: RTSValue]
