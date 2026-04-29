// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

internal let log = RTSLoggers.rtsLog

/// General namespace for the library
public enum RailtracksSwift {
    public static let version = "0.1.0"
    
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
