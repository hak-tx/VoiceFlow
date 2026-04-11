//
//  PasteTarget.swift
//  VoiceFlow
//
//  User-configured destinations for "paste my dictated text into
//  <app>." After Quick Dictate runs, the confirmation banner shows
//  up to four paste target icons; tapping one launches the target
//  app via its URL scheme so the user can paste immediately.
//
//  This is the key differentiator from "just another keyboard" —
//  corporate users whose IT departments block third-party keyboards
//  can still get dictated text into Outlook, Teams, Slack, Notes,
//  etc. in two taps.
//

import Foundation

struct PasteTarget: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// SF Symbol (or asset name) used for the icon.
    var symbolName: String
    /// URL scheme we'll open to launch the target app. Many corporate
    /// apps support a "just open me" URL; for others, opening the app
    /// and relying on the user to paste is the fallback.
    var urlScheme: String
    /// Optional: iOS bundle identifier for apps that expose a more
    /// capable `bundle://` scheme in the future.
    var bundleId: String?
}

extension PasteTarget {
    /// Sensible defaults for a corporate professional. The user can
    /// reorder, remove, or add their own via the PasteTargetsView.
    static let defaults: [PasteTarget] = [
        PasteTarget(
            id: "outlook",
            name: "Outlook",
            symbolName: "envelope.fill",
            urlScheme: "ms-outlook://",
            bundleId: "com.microsoft.Office.Outlook"
        ),
        PasteTarget(
            id: "teams",
            name: "Teams",
            symbolName: "video.fill",
            urlScheme: "msteams://",
            bundleId: "com.microsoft.skype.teams"
        ),
        PasteTarget(
            id: "slack",
            name: "Slack",
            symbolName: "bubble.left.and.bubble.right.fill",
            urlScheme: "slack://open",
            bundleId: "com.tinyspeck.chatlyio"
        ),
        PasteTarget(
            id: "mail",
            name: "Mail",
            symbolName: "envelope",
            urlScheme: "mailto:",
            bundleId: "com.apple.mobilemail"
        ),
        PasteTarget(
            id: "messages",
            name: "Messages",
            symbolName: "message.fill",
            urlScheme: "sms:",
            bundleId: "com.apple.MobileSMS"
        ),
        PasteTarget(
            id: "notes",
            name: "Notes",
            symbolName: "note.text",
            urlScheme: "mobilenotes://",
            bundleId: "com.apple.mobilenotes"
        )
    ]
}
