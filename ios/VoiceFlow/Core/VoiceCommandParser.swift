//
//  VoiceCommandParser.swift
//  VoiceFlow
//
//  Watches the live transcript stream from DictationEngine for wake-
//  word commands. Architecture:
//
//    1. The user configures a wake word (default: "VoiceFlow").
//    2. DictationEngine calls `scan(transcript:engine:)` on every
//       partial result.
//    3. The parser walks through a registry of `VoiceCommand` structs,
//       looks for "<wake word> <phrase>" matches at the tail of the
//       transcript, runs the command's handler, and returns a copy of
//       the transcript with the matched command text stripped.
//    4. The engine replaces liveTranscript with the stripped copy, so
//       commands never reach the cleanup pass or the UI after the
//       brief haptic confirmation.
//
//  To add a new command: build a `VoiceCommand`, append it to
//  `VoiceCommandParser.defaultCommands`. No other wiring needed.
//

import Foundation
import UIKit

/// Context passed to a command's handler so it can mutate the engine
/// or show confirmations without knowing about the whole app graph.
@MainActor
struct VoiceCommandContext {
    let engine: DictationEngine
    let entitlements: EntitlementManager?
    let usageTracker: UsageTracker?

    /// Arbitrary parameter captured by the command, e.g. for
    /// "send to [app name]" this would be the app name.
    let capturedArgument: String?
}

/// Pure description of a voice command. Handlers are async so they
/// can await things like `engine.stop()`.
@MainActor
struct VoiceCommand: Identifiable {
    let id: String
    /// Phrase (without wake word) used to match. Matched case-
    /// insensitively and with loose whitespace.
    let phrase: String
    /// If non-nil, the parser will accept "<phrase> <argument>" and
    /// pass the captured argument to the handler. Used by "send to".
    let acceptsTrailingArgument: Bool
    /// Short display name shown in the haptic confirmation toast.
    let displayName: String
    /// Whether this command requires Pro. Free tier has a small
    /// allow-list defined in FreeTierLimits.
    let proOnly: Bool
    /// The actual side-effect.
    let handler: (VoiceCommandContext) async -> Void
}

@MainActor
final class VoiceCommandParser: ObservableObject {

    // MARK: - State

    /// User-configurable wake word. Default: "VoiceFlow".
    @Published var wakeWord: String {
        didSet {
            UserDefaults.standard.set(wakeWord, forKey: Self.wakeWordKey)
        }
    }

    /// Registry of known commands. New commands can be appended at
    /// runtime (e.g. for plugins) — the matching code walks this in
    /// order.
    private(set) var commands: [VoiceCommand]

    /// Commands already handled this session (keyed by command id +
    /// the transcript suffix they fired on) so we don't re-fire as
    /// partial results keep streaming in.
    private var firedFingerprints: Set<String> = []

    // MARK: - Dependencies for handlers

    weak var entitlements: EntitlementManager?
    weak var usageTracker: UsageTracker?

    // MARK: - Init

    private static let wakeWordKey = "VoiceFlow.wakeWord"

    init(initialCommands: [VoiceCommand]? = nil) {
        let stored = UserDefaults.standard.string(forKey: Self.wakeWordKey)
        self.wakeWord = stored ?? "VoiceFlow"
        self.commands = initialCommands ?? VoiceCommandParser.defaultCommands()
    }

    // MARK: - Registry management

    func register(_ command: VoiceCommand) {
        commands.append(command)
    }

    func resetFiredFingerprints() {
        firedFingerprints.removeAll()
    }

    // MARK: - Matching

    /// Scan the incoming transcript for any registered command at its
    /// tail, execute the command, and return a copy of the transcript
    /// with the matched "wake word + phrase" removed.
    func scan(transcript: String, engine: DictationEngine) -> String {
        // Find the LAST occurrence of the wake word (case insensitive).
        // We only fire on the most recent utterance to avoid re-firing
        // on earlier parts of the transcript as partials stream in.
        guard let wakeRange = transcript.range(
            of: wakeWord,
            options: [.backwards, .caseInsensitive]
        ) else {
            return transcript
        }

        let tail = transcript[wakeRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        if tail.isEmpty { return transcript }
        let tailLower = tail.lowercased()

        for command in commands {
            let phraseLower = command.phrase.lowercased()
            guard tailLower.hasPrefix(phraseLower) else { continue }

            // Extract optional trailing argument (everything after
            // the matched phrase, if the command allows one).
            let afterPhraseLower = String(
                tailLower.dropFirst(phraseLower.count)
            ).trimmingCharacters(in: .whitespaces)
            let argument: String? = command.acceptsTrailingArgument
                ? (afterPhraseLower.isEmpty ? nil : afterPhraseLower)
                : nil

            // Dedupe: don't re-fire the same command on the same
            // utterance as partial results keep streaming.
            let fingerprint = "\(command.id)|\(tailLower)"
            if firedFingerprints.contains(fingerprint) { return transcript }
            firedFingerprints.insert(fingerprint)

            // Free-tier voice command gate.
            if let entitlements, !entitlements.hasPro, command.proOnly {
                engine.errorMessage = "\"\(command.displayName)\" is a Pro voice command."
                return transcript
            }

            // Run the handler. Haptic + visual confirmation here so
            // every command gets consistent UI feedback.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            engine.lastCommandConfirmation = command.displayName

            Task {
                let context = VoiceCommandContext(
                    engine: engine,
                    entitlements: entitlements,
                    usageTracker: usageTracker,
                    capturedArgument: argument
                )
                await command.handler(context)
                usageTracker?.recordVoiceCommand(command.id)
            }

            // Strip everything from the start of the wake word to the
            // end of the transcript (wake word + phrase + optional
            // argument). Operating on `transcript` indices directly so
            // we never mix string index spaces.
            var stripped = transcript
            stripped.removeSubrange(wakeRange.lowerBound..<stripped.endIndex)
            return stripped.trimmingCharacters(in: .whitespaces)
        }

        return transcript
    }

    // MARK: - Built-in command registry

    static func defaultCommands() -> [VoiceCommand] {
        [
            VoiceCommand(
                id: "copy-that",
                phrase: "copy that",
                acceptsTrailingArgument: false,
                displayName: "Copy",
                proOnly: false
            ) { ctx in
                let text = ctx.engine.polishedTranscript.isEmpty
                    ? ctx.engine.liveTranscript
                    : ctx.engine.polishedTranscript
                UIPasteboard.general.string = text
            },
            VoiceCommand(
                id: "clear",
                phrase: "clear",
                acceptsTrailingArgument: false,
                displayName: "Clear",
                proOnly: false
            ) { ctx in
                ctx.engine.clearBuffers()
            },
            VoiceCommand(
                id: "new-paragraph",
                phrase: "new paragraph",
                acceptsTrailingArgument: false,
                displayName: "New Paragraph",
                proOnly: true
            ) { ctx in
                ctx.engine.insertParagraphBreak()
            },
            VoiceCommand(
                id: "stop",
                phrase: "stop",
                acceptsTrailingArgument: false,
                displayName: "Stop",
                proOnly: false
            ) { ctx in
                await ctx.engine.stop()
            },
            VoiceCommand(
                id: "send-to",
                phrase: "send to",
                acceptsTrailingArgument: true,
                displayName: "Send To",
                proOnly: true
            ) { ctx in
                guard let appName = ctx.capturedArgument else { return }
                let text = ctx.engine.polishedTranscript.isEmpty
                    ? ctx.engine.liveTranscript
                    : ctx.engine.polishedTranscript
                UIPasteboard.general.string = text

                // URL schemes for common targets. Unknown targets get
                // a best-effort lookup via app:// — otherwise we just
                // leave the clipboard populated.
                let scheme = Self.urlScheme(forAppName: appName)
                if let url = URL(string: scheme),
                   UIApplication.shared.canOpenURL(url) {
                    await UIApplication.shared.open(url)
                }
            }
        ]
    }

    /// Very small app-name → URL-scheme lookup. Extend freely; for
    /// production we'd maintain this as a JSON config so new targets
    /// don't require a binary update.
    static func urlScheme(forAppName name: String) -> String {
        switch name.lowercased() {
        case "messages", "imessage", "text":  return "sms:"
        case "mail", "email":                 return "mailto:"
        case "slack":                         return "slack://open"
        case "notes":                         return "mobilenotes://"
        case "drafts":                        return "drafts://create"
        case "bear":                          return "bear://x-callback-url/create"
        case "things":                        return "things:///add"
        case "todoist":                       return "todoist://addtask"
        default:                              return "\(name.lowercased())://"
        }
    }
}
