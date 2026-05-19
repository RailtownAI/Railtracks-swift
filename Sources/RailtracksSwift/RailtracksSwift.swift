// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import Crypto

internal let log = RTSLoggers.rtsLog

/// General namespace for the library
public enum RailtracksSwift {
    public static let version = "0.1.0"
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
    
    // TODO: assess the need for static function "call" for Node-alike protocol or equivalent logic
    // TODO: call function's main responsibility is to inject context prior to node invoke/execution
}

//
// MARK: - API key access
//
public extension RailtracksSwift {
    public enum SecretKeys {
        static let openAI = "OpenAI_API_KEY"
    }
    
    public static func getOpenAIAPIKey(
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
