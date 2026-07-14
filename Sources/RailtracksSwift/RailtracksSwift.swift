// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Crypto

internal let log = RTSLoggers.rtsLog

/// General namespace for the library
public enum RailtracksSwift {
    public static let version = "0.1.8"

    /// Set to `true` to enable the per-session `debug_{agent}_{runID}_messages.json` file written to the
    /// app's Documents directory after each LLM call. Only has effect in DEBUG builds.
    /// Configure once at app startup before any flow runs.
    public nonisolated(unsafe) static var debugMessageFileEnabled: Bool = false

    /// Directory where flow graph JSON files are written after each flow run.
    /// Defaults to an `sessions` subfolder of the app's Documents directory.
    /// Configure once at app startup before any flow runs.
    public nonisolated(unsafe) static var flowGraphOutputDirectory: URL = (
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        ?? FileManager.default.temporaryDirectory
    ).appendingPathComponent("sessions", isDirectory: true)

    /// Directory where evaluation report JSON files are written by `evaluate(...)`.
    /// Defaults to an `evaluations` subfolder of the app's Documents directory.
    /// Configure once at app startup before running an evaluation.
    public nonisolated(unsafe) static var evaluationOutputDirectory: URL = (
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        ?? FileManager.default.temporaryDirectory
    ).appendingPathComponent("evaluations", isDirectory: true)

    /// Maximum character length for `content` passed to signpost IO events before truncation.
    /// Raise this to see more content in Instruments; lower it if events appear empty or malformed.
    /// Configure once at app startup before any flow runs.
    public nonisolated(unsafe) static var signpostIOContentLimit: Int = 512
}

//
// MARK: - global static functions
//
public extension RailtracksSwift {
    /// A hash algorithm that provide consistent hex string with same input string
    internal static func equalityHash(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        let hexString = hash.compactMap({ String(format: "%02x", $0) }).joined()
        return hexString
    }
    
    // TODO: when implementing context or context-injection for agent
    // assess the need for static function "call" for Node-alike protocol or equivalent logic
    // call function's main responsibility is to inject context prior to node invoke/execution
}

