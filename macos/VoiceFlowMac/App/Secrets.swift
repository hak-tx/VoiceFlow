//
//  Secrets.swift
//  VoiceFlowMac
//
//  API key management. The key is stored in macOS Keychain via the
//  secure storage helper, NOT in UserDefaults or source code. Users
//  configure it in Settings → About → API Key.
//
//  For development, set the ANTHROPIC_API_KEY environment variable
//  or enter it in the Settings UI on first launch.
//

import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.hak-tx.voiceflow.mac", category: "Secrets")

enum Secrets {

    private static let keychainService = "com.hak-tx.voiceflow.mac"
    private static let keychainAccount = "anthropic-api-key"

    /// The Anthropic API key. Reads from:
    ///   1. macOS Keychain (set via Settings UI)
    ///   2. ANTHROPIC_API_KEY environment variable (dev fallback)
    ///   3. Empty string (triggers the "configure your key" error)
    static var anthropicAPIKey: String {
        // 1. Keychain
        if let key = readFromKeychain(), !key.isEmpty {
            return key
        }
        // 2. Environment variable (for development)
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }
        // 3. Not configured
        return ""
    }

    /// Whether a valid-looking API key is configured.
    static var isAPIKeyConfigured: Bool {
        let key = anthropicAPIKey
        return !key.isEmpty && key != "sk-ant-REPLACE-ME"
    }

    /// Save an API key to the macOS Keychain. Called from the Settings UI.
    static func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)

        // Delete any existing key first.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !key.isEmpty else { return }

        // Add the new key.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Failed to save API key to Keychain: \(status)")
        } else {
            log.info("API key saved to Keychain")
        }
    }

    /// Read the API key from macOS Keychain.
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
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
