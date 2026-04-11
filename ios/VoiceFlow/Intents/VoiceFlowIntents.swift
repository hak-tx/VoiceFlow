//
//  VoiceFlowIntents.swift
//  VoiceFlow
//
//  App Intents. The hero intent is `QuickDictateIntent` — it appears
//  in Shortcuts, the Action Button picker, the Lock Screen widget
//  gallery, and Control Center. When invoked it opens the app
//  straight into QuickDictateView and auto-starts recording.
//
//  Other intents:
//   - GetLastDictationIntent - returns the most recent polished
//     transcript from DictationHistory (no UI).
//   - DictateWithVoiceFlowIntent - opens full DictationView.
//   - DictateAndCopyIntent - opens, records, copies.
//   - DictateAndShareToAppIntent - opens, records, launches target.
//

import Foundation
import AppIntents
import UIKit

// MARK: - Quick Dictate (hero)

struct QuickDictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Dictate"
    static var description = IntentDescription(
        "Start a Quick Dictate session. Recording begins immediately and auto-stops on silence. The polished text is copied to your clipboard."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentLaunchFlags.shared.autoStartOnLaunch = true
        IntentLaunchFlags.shared.launchTarget = .quickDictate
        IntentLaunchFlags.shared.autoCopyOnFinish = true
        return .result(
            dialog: IntentDialog("VoiceFlow is listening…")
        )
    }
}

// MARK: - Get Last Dictation (no-UI)

struct GetLastDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Dictation"
    static var description = IntentDescription(
        "Return the most recent polished dictation from VoiceFlow. Useful for Shortcuts automations that feed the text into other apps."
    )
    /// Runs without opening the app.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // TODO: persist history in an App Group so we can read it
        // from the background intent process. For now this returns
        // the clipboard contents, which is populated by the most
        // recent Quick Dictate. Once the App Group is wired up,
        // read from DictationHistoryStore directly.
        let text = UIPasteboard.general.string ?? ""
        return .result(value: text)
    }
}

// MARK: - Dictate with VoiceFlow (full in-app flow)

struct DictateWithVoiceFlowIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate with VoiceFlow"
    static var description = IntentDescription(
        "Open VoiceFlow and start recording in the full dictation view."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLaunchFlags.shared.autoStartOnLaunch = true
        IntentLaunchFlags.shared.launchTarget = .fullDictationView
        return .result()
    }
}

// MARK: - Dictate and Copy

struct DictateAndCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate and Copy"
    static var description = IntentDescription(
        "Record, clean up the transcript, and copy it to the clipboard."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        IntentLaunchFlags.shared.autoStartOnLaunch = true
        IntentLaunchFlags.shared.launchTarget = .quickDictate
        IntentLaunchFlags.shared.autoCopyOnFinish = true
        return .result(value: "")
    }
}

// MARK: - Dictate and Share to App

struct DictateAndShareToAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate and Share"
    static var description = IntentDescription(
        "Record, clean up, and open a target app with the transcript on the clipboard."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Target App")
    var appName: String

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLaunchFlags.shared.autoStartOnLaunch = true
        IntentLaunchFlags.shared.launchTarget = .quickDictate
        IntentLaunchFlags.shared.autoCopyOnFinish = true
        IntentLaunchFlags.shared.autoShareTargetApp = appName
        return .result()
    }
}

// MARK: - Shared flags the app consults on launch

enum IntentLaunchTarget {
    case quickDictate
    case fullDictationView
}

@MainActor
final class IntentLaunchFlags {
    static let shared = IntentLaunchFlags()

    var autoStartOnLaunch: Bool = false
    var autoCopyOnFinish: Bool = false
    var autoShareTargetApp: String? = nil
    var launchTarget: IntentLaunchTarget = .quickDictate

    func consume() {
        autoStartOnLaunch = false
        autoCopyOnFinish = false
        autoShareTargetApp = nil
        launchTarget = .quickDictate
    }

    private init() {}
}

// MARK: - App Shortcuts

struct VoiceFlowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickDictateIntent(),
            phrases: [
                "Quick Dictate with \(.applicationName)",
                "\(.applicationName) quick dictate",
                "Start \(.applicationName)"
            ],
            shortTitle: "Quick Dictate",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: GetLastDictationIntent(),
            phrases: [
                "Get my last \(.applicationName) dictation",
                "Last dictation from \(.applicationName)"
            ],
            shortTitle: "Last Dictation",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: DictateWithVoiceFlowIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Dictate in \(.applicationName)"
            ],
            shortTitle: "Full Dictate",
            systemImageName: "mic.fill"
        )
    }
}
