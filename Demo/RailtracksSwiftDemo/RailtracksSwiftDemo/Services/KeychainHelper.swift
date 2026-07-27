//
//  KeychainHelper.swift
//  RailtracksSwiftDemo
//

import Foundation
import Security

enum KeychainHelper {
    static let service = "ai.railtown.RailtracksSwiftDemo"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(
            query as CFDictionary, attributes as CFDictionary
        ) == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension KeychainHelper {
    static let openAIAccount = "openai-api-key"

    static func readOpenAIKey() -> String? {
        read(account: openAIAccount)
    }

    static func writeOpenAIKey(_ key: String) {
        write(key, account: openAIAccount)
    }
}

extension KeychainHelper {
    static let anthropicAccount = "anthropic-api-key"

    static func readAnthropicKey() -> String? {
        read(account: anthropicAccount)
    }

    static func writeAnthropicKey(_ key: String) {
        write(key, account: anthropicAccount)
    }
}

/// The cloud providers the demo can prompt an API key for. On-device (AppleAI) needs no key, so it
/// isn't represented here. Lets the shared key-setup UI read/write the correct Keychain slot.
enum DemoAPIKeyProvider {
    case openAI
    case anthropic

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        }
    }

    func readKey() -> String? {
        switch self {
        case .openAI:
            return KeychainHelper.readOpenAIKey()
        case .anthropic:
            return KeychainHelper.readAnthropicKey()
        }
    }

    func writeKey(_ key: String) {
        switch self {
        case .openAI:
            KeychainHelper.writeOpenAIKey(key)
        case .anthropic:
            KeychainHelper.writeAnthropicKey(key)
        }
    }
}
