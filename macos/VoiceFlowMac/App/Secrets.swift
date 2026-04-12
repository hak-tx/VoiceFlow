//
//  Secrets.swift
//  VoiceFlowMac
//
//  API key configuration. For now, paste your key on the line below.
//  Later this will move to a proper user-facing configuration flow.
//

import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.hak-tx.voiceflow.mac", category: "Secrets")

enum Secrets {

    // ┌─────────────────────────────────────────────────┐
    // │  PASTE YOUR ANTHROPIC API KEY HERE:              │
    // └─────────────────────────────────────────────────┘
    private static let hardcodedKey = "sk-ant-REPLACE-ME"

    private static let keychainService = "com.hak-tx.voiceflow.mac"
    private static let keychainAccount = "anthropic-api-key"

    /// The Anthropic API key. Priority:
    ///   1. Keychain (set via the app's menu bar popover)
    ///   2. ANTHROPIC_API_KEY environment variable
    ///   3. Hardcoded key above
    static var anthropicAPIKey: String {
        if let key = readFromKeychain(), !key.isEmpty, key != "sk-ant-REPLACE-ME" {
            return key
        }
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }
        return hardcodedKey
    }

    static var isAPIKeyConfigured: Bool {
        let key = anthropicAPIKey
        return !key.isEmpty && key != "sk-ant-REPLACE-ME"
    }

    static func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard !key.isEmpty else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Keychain save failed: \(status)")
        }
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
