//
//  TonePreset.swift
//  VoiceFlowMac
//
//  Tone presets control how aggressively Claude rewrites the raw
//  transcript. Each preset maps to a system-prompt snippet merged
//  into the cleanup request. Shared logic with the iOS app.
//

import Foundation

enum TonePreset: String, CaseIterable, Identifiable, Codable {
    case verbatim
    case email
    case slack
    case notes
    case code
    case socialPost
    case professional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verbatim:     return "Verbatim"
        case .email:        return "Email"
        case .slack:        return "Slack"
        case .notes:        return "Notes"
        case .code:         return "Code"
        case .socialPost:   return "Social Post"
        case .professional: return "Professional"
        }
    }

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
        case .code:
            return "Preserves HTTP verbs, git terms, identifiers, symbols."
        case .socialPost:
            return "Punchy, short, emoji-aware."
        case .professional:
            return "Formal tone, polished grammar."
        }
    }

    var symbolName: String {
        switch self {
        case .verbatim:     return "text.quote"
        case .email:        return "envelope"
        case .slack:        return "bubble.left.and.bubble.right"
        case .notes:        return "list.bullet"
        case .code:         return "chevron.left.forwardslash.chevron.right"
        case .socialPost:   return "megaphone"
        case .professional: return "briefcase"
        }
    }

    /// System-prompt fragment merged into the cleanup request.
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
        case .code:
            return """
            The speaker is a software engineer dictating technical content — \
            code review comments, standup notes, PR descriptions, design docs, \
            debugging thoughts. Apply code-aware cleanup:

            - PRESERVE HTTP VERBS EXACTLY. GET, POST, PUT, PATCH, DELETE, HEAD, \
            OPTIONS stay in UPPERCASE. If the speech-to-text wrote them in \
            mixed case ("Get request"), fix to "GET request".
            - PRESERVE GIT / DEV TERMS. "pull request", "PR", "merge conflict", \
            "rebase", "cherry-pick", "fast-forward", "branch", "commit", \
            "staging", "main", "origin", "upstream" — these are sacred.
            - PRESERVE IDENTIFIERS AND SYMBOLS. CamelCase (getUserById), \
            snake_case (user_id), kebab-case (feature-flag), SCREAMING_SNAKE \
            (MAX_RETRIES), dotted paths (foo.bar.baz).
            - SPOKEN SYMBOLS to REAL SYMBOLS when clearly meant as code syntax: \
            "dot" -> . | "arrow" -> -> | "fat arrow" -> => | \
            "double equals" -> == | "not equals" -> != | etc.
            - PRESERVE VERSION NUMBERS, ERROR CODES, FILE PATHS, URLS.
            - PRESERVE ACRONYMS. PR, API, SDK, CLI, CI/CD, SLO, SLA, p95, k8s, etc.
            - WRAP CODE SNIPPETS IN BACKTICKS when the speaker clearly dictated \
            a command or function call.
            """
        case .socialPost:
            return """
            Format the output as a short social media post:
            - Trim aggressively. Cut anything that isn't the core message.
            - Keep it under 280 characters if possible.
            - Preserve any emoji the speaker mentioned as actual emoji characters.
            - Use hashtags sparingly, only if the speaker explicitly said "hashtag X".
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

    static let storageKey = "VoiceFlowMac.activeTonePreset"

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
