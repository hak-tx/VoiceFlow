//
//  TonePreset.swift
//  VoiceFlow
//
//  A tone preset is a fixed cleanup style the user can pick to control
//  how aggressively Claude rewrites the raw transcript during the
//  polish pass. Each preset maps to a different system-prompt snippet
//  that gets merged into the cleanup request.
//
//  Default is `.verbatim` (lightest possible cleanup — just filler
//  removal + punctuation). Presets escalate from there.
//

import Foundation

enum TonePreset: String, CaseIterable, Identifiable, Codable {
    case verbatim
    case email
    case slack
    case notes
    case socialPost
    case professional

    var id: String { rawValue }

    /// Display name shown in the picker UI.
    var title: String {
        switch self {
        case .verbatim:     return "Verbatim"
        case .email:        return "Email"
        case .slack:        return "Slack"
        case .notes:        return "Notes"
        case .socialPost:   return "Social Post"
        case .professional: return "Professional"
        }
    }

    /// One-line description shown in the picker.
    var subtitle: String {
        switch self {
        case .verbatim:
            return "Lightest cleanup. Filler + punctuation only."
        case .email:
            return "Structured greeting, paragraphs, sign-off."
        case .slack:
            return "Casual, concise, chat-friendly."
        case .notes:
            return "Bullet points and short phrases."
        case .socialPost:
            return "Punchy, short, emoji-aware."
        case .professional:
            return "Formal tone, polished grammar."
        }
    }

    /// SF Symbol name used in the picker button.
    var symbolName: String {
        switch self {
        case .verbatim:     return "text.quote"
        case .email:        return "envelope"
        case .slack:        return "bubble.left.and.bubble.right"
        case .notes:        return "list.bullet"
        case .socialPost:   return "megaphone"
        case .professional: return "briefcase"
        }
    }

    /// Whether this preset is gated to Pro tier. Verbatim + email +
    /// notes are available on free; the rest require Pro.
    var requiresPro: Bool {
        switch self {
        case .verbatim, .email, .notes: return false
        case .slack, .socialPost, .professional: return true
        }
    }

    /// System-prompt fragment merged into the cleanup request. This is
    /// appended after the base rules (filler removal, punctuation,
    /// preserve voice) so it influences style without overriding the
    /// no-paraphrase guarantee.
    var systemPromptFragment: String {
        switch self {
        case .verbatim:
            return """
            Apply only the minimum cleanup needed: remove fillers, fix
            punctuation, and correct obvious self-corrections. Do NOT
            restructure sentences or change word choice.
            """
        case .email:
            return """
            Format the output as an email body. Add appropriate
            paragraph breaks. If the speaker naturally greeted or
            signed off, preserve that; otherwise do not invent one.
            Keep the speaker's tone.
            """
        case .slack:
            return """
            Format the output for a Slack / chat message: short,
            casual, direct. Split into multiple short messages only if
            the speaker paused clearly. Preserve the casual tone.
            """
        case .notes:
            return """
            Format the output as concise notes. Use bullet points
            where the speaker listed items. Keep sentences short.
            """
        case .socialPost:
            return """
            Format the output as a short social media post. Trim
            aggressively. Preserve emoji the speaker mentioned
            ("heart emoji", "fire emoji") as the actual emoji
            characters.
            """
        case .professional:
            return """
            Apply a formal, professional tone. Fix grammar
            thoroughly. Do not add content the speaker did not say,
            but you may tighten phrasing for clarity.
            """
        }
    }

    static let storageKey = "VoiceFlow.activeTonePreset"

    static func loadPersisted() -> TonePreset {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let preset = TonePreset(rawValue: raw) {
            return preset
        }
        return .verbatim
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}
