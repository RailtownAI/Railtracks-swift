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
    /// File write or encoding failed. The associated value is the attempted file path, if known.
    case writeFileFailed(String? = nil)
    case invalidInvocation(String)
    case invalidSchema(String)
    case missingAPIKey(String)
    /// Selected provider is not available on the current OS version (e.g. AppleAI below macOS/iOS 26).
    case providerUnavailable(String)
}
