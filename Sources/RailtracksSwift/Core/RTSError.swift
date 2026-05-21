//
//  RTSError.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation

public enum RTSError: Error {
    case missingInput(String)
    case missingOutput(String)
    case encodingFailed(String? = nil)
    case decodingFailed(String? = nil)
    case writeFileFailed(String? = nil)
    case invalidInvocation(String)
    case missingAPIKey(String)
}
