// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Crypto

internal let log = RTSLoggers.rtsLog

/// General namespace for the library
public enum RailtracksSwift {
    public static let version = "0.2.0"

    /// Set to `true` to enable the per-session `debug_{agent}_{runID}_messages.json` file written to the
    /// app's Documents directory after each LLM call. Only has effect in DEBUG builds.
    /// Configure once at app startup before any flow runs.
    public nonisolated(unsafe) static var debugMessageFileEnabled: Bool = false

    /// Root directory for everything the library writes. Defaults to the app's Documents
    /// directory; configure once at app startup, before any flow runs.
    ///
    /// This is the **only** output path an app sets. The subfolders beneath it are fixed —
    /// `sessions` for flow-graph traces, `events` for observability event logs, `evaluations`
    /// for evaluation reports — so the layout is an invariant a consumer can rely on, and
    /// redirecting one artifact cannot leave the others behind in the old location.
    public nonisolated(unsafe) static var outputDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)
        .first
        ?? FileManager.default.temporaryDirectory

    /// Where flow graph JSON files are written after each flow run: `sessions` under
    /// ``outputDirectory``.
    public static var flowGraphOutputDirectory: URL {
        outputDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Where evaluation report JSON files are written by `evaluate(...)`: `evaluations` under
    /// ``outputDirectory``.
    public static var evaluationOutputDirectory: URL {
        outputDirectory.appendingPathComponent("evaluations", isDirectory: true)
    }

    /// Where ``RTSEventWriter`` appends observability event JSONL files, one per session
    /// (`<session id>.jsonl`): `events` under ``outputDirectory``.
    public static var eventsOutputDirectory: URL {
        outputDirectory.appendingPathComponent("events", isDirectory: true)
    }

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

