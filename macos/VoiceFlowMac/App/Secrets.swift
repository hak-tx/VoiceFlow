//
//  Secrets.swift
//  VoiceFlowMac
//
//  API key holder. Replace the placeholder before building.
//
//  IMPORTANT: Do NOT commit real keys. Add this file to .gitignore
//  or use a Secrets.swift.example pattern.
//

import Foundation

enum Secrets {
    /// Anthropic API key for Claude cleanup.
    /// Replace "sk-ant-REPLACE-ME" with your real key.
    static let anthropicAPIKey: String = "sk-ant-REPLACE-ME"
}
