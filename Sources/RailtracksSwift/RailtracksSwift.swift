// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Crypto

internal let log = RTSLoggers.rtsLog

/// General namespace for the library
public enum RailtracksSwift {
    public static let version = "0.1.1"

    /// Set to `false` to disable the per-session `debug_{agent}_{runID}_messages.json` file written to the
    /// app's Documents directory after each LLM call. Only has effect in DEBUG builds.
    /// Configure once at app startup before any flow runs.
    public nonisolated(unsafe) static var debugMessageFileEnabled: Bool = true
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

//
// MARK: - API key access
//
public extension RailtracksSwift {
    enum SecretKeys {
        static let openAI = "OpenAI_API_KEY"
    }
    
    static func getOpenAIAPIKey(
        filename: String = "Secrets",
    ) -> String? {
        guard let filePath = Bundle.main.path(forResource: filename, ofType: "plist") else {
            return nil
        }
        
        let plist = NSDictionary(contentsOfFile: filePath)
        let value = plist?.object(forKey: SecretKeys.openAI) as? String
        return value
    }
}
