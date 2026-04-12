//
//  Secrets.swift
//  VoiceFlowMac
//
//  API key storage. Uses UserDefaults — simple, no Keychain prompts.
//

import Foundation

enum Secrets {

    private static let apiKeyDefaultsKey = "VoiceFlowMac.anthropicAPIKey"

    static var anthropicAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: apiKeyDefaultsKey),
           !key.isEmpty, key != "sk-ant-REPLACE-ME" {
            return key
        }
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }
        return ""
    }

    static var isAPIKeyConfigured: Bool {
        !anthropicAPIKey.isEmpty
    }

    static func saveAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: apiKeyDefaultsKey)
    }
}
