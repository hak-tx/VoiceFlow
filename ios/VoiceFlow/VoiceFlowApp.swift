//
//  VoiceFlowApp.swift
//  VoiceFlow
//
//  App entry point. Wires every manager together and injects them
//  into the environment.
//
//  Root-level behavior:
//   - If onboarding hasn't been completed, show OnboardingView full
//     screen until `settings.onboardingDone` flips.
//   - Otherwise show DictationView (the full in-app experience).
//   - If the app was launched by a QuickDictateIntent (or any other
//     intent that set `IntentLaunchFlags.shared.autoStartOnLaunch`),
//     present QuickDictateView as a full-screen cover immediately.
//

import SwiftUI

@main
struct VoiceFlowApp: App {
    @StateObject private var engine = DictationEngine()
    @StateObject private var vocabManager = VocabPackManager()
    @StateObject private var usageTracker = UsageTracker()
    @StateObject private var commandParser = VoiceCommandParser()
    @StateObject private var history = DictationHistoryStore()
    @StateObject private var pasteTargets = PasteTargetsManager()
    @StateObject private var settings = AppSettings()

    // Shared singleton — every gated feature does
    // `EntitlementManager.shared.hasPro`. Injected into the
    // environment so SwiftUI views get reactive updates.
    private let entitlements = EntitlementManager.shared

    @State private var intentQuickDictate = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(vocabManager)
                .environmentObject(entitlements)
                .environmentObject(usageTracker)
                .environmentObject(commandParser)
                .environmentObject(history)
                .environmentObject(pasteTargets)
                .environmentObject(settings)
                .preferredColorScheme(settings.preferredColorScheme)
                .task {
                    wireDependencies()
                    await vocabManager.loadInstalledPacks()
                    await vocabManager.refreshCatalog()

                    // Auto-launch Quick Dictate if an intent set the
                    // flag while the app was cold-launched.
                    if IntentLaunchFlags.shared.autoStartOnLaunch,
                       IntentLaunchFlags.shared.launchTarget == .quickDictate {
                        IntentLaunchFlags.shared.consume()
                        intentQuickDictate = true
                    }
                }
                .fullScreenCover(isPresented: $intentQuickDictate) {
                    QuickDictateView()
                        .environmentObject(engine)
                        .environmentObject(vocabManager)
                        .environmentObject(history)
                        .environmentObject(pasteTargets)
                        .environmentObject(settings)
                }
        }
    }

    /// Wire cross-references between managers. Called once on launch.
    private func wireDependencies() {
        vocabManager.entitlements = entitlements
        vocabManager.usageTracker = usageTracker

        commandParser.entitlements = entitlements
        commandParser.usageTracker = usageTracker

        history.entitlements = entitlements

        engine.vocabManager = vocabManager
        engine.entitlements = entitlements
        engine.usageTracker = usageTracker
        engine.commandParser = commandParser
    }
}

// MARK: - Root decision: onboarding vs. main

private struct RootView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if settings.onboardingDone {
            DictationView()
        } else {
            OnboardingView()
        }
    }
}
