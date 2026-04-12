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
            Apply only the minimum cleanup needed: remove fillers and mic test \
            chatter, fix punctuation and capitalization, correct obvious speech-\
            to-text errors, and collapse self-corrections. Do NOT restructure \
            sentences, change word choice, or reformat. Output as flowing prose.
            """
        case .email:
            return """
            Format the output as a polished email body:
            - Break content into clear paragraphs with blank lines between them.
            - Use complete sentences and a professional tone.
            - If the speaker opened with a greeting ("Hey John", "Hi team"), keep \
            it as a standalone first line. If they signed off ("Thanks, Brian"), \
            keep it as a standalone last line. Do NOT invent a greeting or \
            sign-off if the speaker didn't include one.
            - Keep the speaker's tone. If they were casual, keep it casual; if \
            formal, keep it formal.
            """
        case .slack:
            return """
            Format the output as a Slack / chat message:
            - Short, direct, conversational.
            - Trim anything that reads like formal letter-writing.
            - If the speaker clearly split into multiple thoughts, break into \
            separate short messages (one per line).
            - Preserve casual tone, contractions, and any emoji the speaker \
            mentioned ("heart emoji" -> actual emoji).
            """
        case .notes:
            return """
            Format the output as clean notes with bullet points:
            - Any list, sequence of items, or enumeration the speaker dictated \
            MUST be converted into a bulleted list (use "- " prefix).
            - Keep each bullet short — one idea per bullet. Break long \
            sentences into multiple bullets.
            - If the speaker dictated a single paragraph that isn't obviously \
            a list, keep it as prose but still clean it up.
            - Use nested bullets ("  - " indent) for sub-items.
            - When the speaker says "bullet point" or "next bullet" or similar, \
            treat that as a separator, don't include the literal words.
            """
        case .socialPost:
            return """
            Format the output as a short social media post:
            - Trim aggressively. Cut anything that isn't the core message.
            - Keep it under 280 characters if possible.
            - Preserve any emoji the speaker mentioned ("heart emoji", "fire \
            emoji") as the actual emoji characters.
            - Use hashtags sparingly, only if the speaker explicitly said \
            "hashtag X".
            - Punchy tone. Short sentences.
            """
        case .professional:
            return """
            Apply a formal, professional tone:
            - Fix grammar thoroughly. Use complete sentences, proper subject-\
            verb agreement, active voice where possible.
            - Tighten phrasing for clarity — replace "a lot of" with "many", \
            "kind of" with "somewhat", etc. But do NOT add content the \
            speaker didn't say.
            - Remove casual hedges ("I think maybe", "you know") unless the \
            speaker intentionally equivocated.
            - Use proper business English throughout.
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
