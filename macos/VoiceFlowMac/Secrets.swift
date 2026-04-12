//
//  Secrets.swift
//  VoiceFlowMac
//
//  Copy this file and drop in your real Anthropic API key.
//  The populated Secrets.swift should be gitignored.
//
//  Get a key at: https://console.anthropic.com/
//

import Foundation

enum Secrets {
    /// Anthropic API key used by MacDictationEngine -> ClaudeCleanup.
    /// Treat this like a password; never commit the populated file.
    static let anthropicAPIKey = "sk-ant-REPLACE-ME"
}
