//
//  ClaudeCleanup.swift
//  VoiceFlow
//
//  Claude-powered transcript cleanup. Accepts a raw transcript, an
//  active TonePreset, and a set of active vocab pack material, and
//  returns a polished transcript.
//
//  Model selection:
//   - Free tier & standard Pro cleanup: claude-haiku-4-5-20251001
//   - Pro Polish (Pro users with Pro Polish enabled): claude-sonnet-4-6
//
//  The caller (DictationEngine) is responsible for deciding which
//  model tier to request via the `model` parameter.
//

import Foundation

/// A tiny, strongly-typed Claude Messages API client scoped to the
/// specific job of cleaning up dictation transcripts.
struct ClaudeCleanup {

    // MARK: - Model IDs

    enum Model: String {
        /// Free tier and default Pro cleanup.
        case haiku = "claude-haiku-4-5-20251001"
        /// Pro Polish. Sonnet 4.6 is the strongest non-Opus tier.
        /// Double-check in the Anthropic docs before release.
        case sonnet = "claude-sonnet-4-6"
    }

    // MARK: - Request shape

    struct Request {
        let rawTranscript: String
        let tone: TonePreset
        let packPromptHints: String?
        let packTermsBlock: String?
        let model: Model
    }

    // MARK: - Errors

    enum CleanupError: Error, LocalizedError {
        case missingAPIKey
        case emptyTranscript
        case httpError(status: Int, body: String)
        case decodingFailed(Error)
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key configured. See Secrets.swift.example."
            case .emptyTranscript:
                return "Nothing to clean up."
            case .httpError(let status, let body):
                return "Claude API HTTP \(status): \(body)"
            case .decodingFailed(let err):
                return "Claude API response decoding failed: \(err.localizedDescription)"
            case .network(let err):
                return "Network error: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - Constants

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"
    private static let maxTokens = 4096

    // MARK: - Shared instance

    static let shared = ClaudeCleanup()

    // MARK: - Public API

    /// Fire a cleanup request against the Claude Messages API and
    /// return the polished text.
    func clean(_ request: Request) async throws -> String {
        let trimmed = request.rawTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CleanupError.emptyTranscript }

        let apiKey = Secrets.anthropicAPIKey
        guard !apiKey.isEmpty, apiKey != "sk-ant-REPLACE-ME" else {
            throw CleanupError.missingAPIKey
        }

        let systemPrompt = Self.buildSystemPrompt(
            tone: request.tone,
            packPromptHints: request.packPromptHints,
            packTermsBlock: request.packTermsBlock
        )

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.addValue(apiKey, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = [
            "model": request.model.rawValue,
            "max_tokens": Self.maxTokens,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": trimmed
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CleanupError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CleanupError.httpError(status: -1, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw CleanupError.httpError(status: http.statusCode, body: snippet)
        }

        struct APIResponse: Decodable {
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
            let content: [ContentBlock]
        }

        do {
            let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
            let text = decoded.content
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw CleanupError.decodingFailed(error)
        }
    }

    // MARK: - Prompt assembly

    /// Build the full system prompt by layering the base cleanup
    /// rules, the active tone preset, active vocab pack prompt hints,
    /// and the active vocab pack terms/phrases block.
    static func buildSystemPrompt(
        tone: TonePreset,
        packPromptHints: String?,
        packTermsBlock: String?
    ) -> String {
        var parts: [String] = []

        parts.append("""
        You are a transcript cleanup assistant for a voice dictation app. You will receive a raw Apple speech-to-text transcript. Your job is to transform it from raw dictation into polished, readable text the user actually wants to paste into an email, message, or document. BE CONFIDENT AND ACTUALLY CLEAN IT UP — do not return the input nearly unchanged. A user who wanted raw speech would not have pressed Stop.

        Apply ALL of these rules aggressively:

        1. REMOVE filler words and throat-clearing: um, uh, like, you know, sort of, basically, I mean, so yeah, right?, actually (when it's filler), kind of, etc.

        2. REMOVE mic test chatter: phrases like "testing testing 123", "hello hello", "check check", "one two three", repeated words clearly spoken to calibrate the mic, etc. These are never part of the real message.

        3. FIX punctuation and capitalization. Add periods, commas, question marks where sentences end or pauses occur. Capitalize proper nouns, sentence starts, and acronyms. Break run-on sentences into multiple sentences where appropriate.

        4. COLLAPSE self-corrections: "go to the store, I mean the office" -> "go to the office". "Her name is Jen, uh, Jenny" -> "Her name is Jenny".

        5. FIX OBVIOUS SPEECH-TO-TEXT ERRORS. Apple's speech recognizer frequently mis-hears domain terms. If a phrase is clearly wrong given the surrounding context, correct it to what the speaker obviously meant. Examples:
           - "bowl of points" in a note-taking context -> "bullet points"
           - "two pieces of mine" when listing items -> "two pizzas of mine" is NOT a fix; only fix when context makes the intent unambiguous
           - "sink the code" in engineering context -> "sync the code"
           - "there their they're" confusions based on grammar
           Use your judgment. Only fix unambiguous errors. When in doubt, leave it.

        6. PRESERVE the speaker's voice, word choice, and meaning BEYOND these fixes. Do NOT paraphrase whole sentences, summarize, add opinions, or invent content the speaker didn't say. Do NOT answer questions in the transcript — just clean them up as text.

        7. Output ONLY the cleaned transcript. No preamble, no "Here is the cleaned version:", no explanation, no markdown code fences, no quoting.
        """)

        parts.append("Tone preset: \(tone.title).\n" + tone.systemPromptFragment)

        if let hints = packPromptHints, !hints.isEmpty {
            parts.append("Domain context: " + hints)
        }
        if let terms = packTermsBlock, !terms.isEmpty {
            parts.append(
                "The speaker may use these domain terms; preserve their exact " +
                "spelling and capitalization:\n" + terms
            )
        }

        return parts.joined(separator: "\n\n")
    }
}
