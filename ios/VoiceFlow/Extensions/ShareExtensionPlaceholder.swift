//
//  ShareExtensionPlaceholder.swift
//  VoiceFlow
//
//  Placeholder for the Share Extension target. A real iOS Share
//  extension must live in its own target (File → New → Target →
//  Share Extension). This file exists so the architecture and file
//  layout are in place — when you add the real target:
//
//  1. File → New → Target → Share Extension, name it
//     "VoiceFlowShare".
//  2. Set the new target's deployment target to iOS 17.0.
//  3. In the new target's Info.plist, under NSExtension →
//     NSExtensionAttributes → NSExtensionActivationRule, specify
//     NSExtensionActivationSupportsText = YES so the system offers
//     VoiceFlow as a share target when text is selected.
//  4. Replace the stock ShareViewController with something that
//     reads the inbound text and calls ClaudeCleanup.shared.clean(...)
//     with the user's current tone preset + active vocab packs.
//  5. To share code (ClaudeCleanup, TonePreset, VocabPack,
//     VocabPackManager, Secrets), either check their target
//     membership for the new extension target OR refactor them into
//     a shared Swift Package that both the app and the extension
//     depend on (recommended).
//
//  For now this file just defines the protocol surface the extension
//  will use so we can wire call-sites ahead of time.
//

import Foundation

/// Contract the Share extension will eventually implement. Kept here
/// in the main target as a design anchor.
protocol VoiceFlowShareHandling {
    func cleanupInboundText(
        _ text: String
    ) async throws -> String
}

/// Reference implementation the extension can drop in once its
/// target is wired. Uses the same ClaudeCleanup path as the main app
/// so tone presets and vocab packs stay consistent.
struct VoiceFlowShareCleanupBridge: VoiceFlowShareHandling {
    // TODO: when the extension target exists, inject the user's
    // current TonePreset + VocabPackManager state via App Group
    // UserDefaults (suite: "group.com.hak-tx.voiceflow").
    func cleanupInboundText(_ text: String) async throws -> String {
        let request = ClaudeCleanup.Request(
            rawTranscript: text,
            tone: .verbatim,
            packPromptHints: nil,
            packTermsBlock: nil,
            model: .haiku
        )
        return try await ClaudeCleanup.shared.clean(request)
    }
}
