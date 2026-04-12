//
//  Secrets.swift
//  VoiceFlowMac
//
//  Copy this file from the iOS project's Secrets.swift or create one
//  with your real Anthropic API key. The real Secrets.swift is gitignored.
//
//  Get a key at: https://console.anthropic.com/
//

import Foundation

enum Secrets {
    /// Anthropic API key used by MacDictationEngine -> ClaudeCleanup.
    /// Treat this like a password; never commit the populated file.
    static let anthropicAPIKey = "sk-ant-REPLACE-ME"
}
