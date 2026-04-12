//
//  VoiceFlowMacApp.swift
//  VoiceFlowMac
//
//  macOS menu-bar app entry point. VoiceFlow lives in the menu bar
//  with no Dock icon. The user triggers dictation system-wide via
//  a double-Control (^^) hotkey. A floating overlay appears at the
//  cursor showing live transcription, and when dictation stops the
//  text is cleaned up by Claude Haiku and inserted at the cursor.
//

import SwiftUI

@main
struct VoiceFlowMacApp: App {

    // MARK: - State objects

    @StateObject private var settings = MacAppSettings()
    @StateObject private var dictationEngine = MacDictationEngine()
    @StateObject private var vocabManager = MacVocabPackManager()
    @StateObject private var hotkeyManager = GlobalHotkeyManager()
    @StateObject private var overlayController = OverlayPanelController()
    @StateObject private var accessibilityManager = AccessibilityTextManager()

    // MARK: - App lifecycle

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar extra — the only visible chrome when idle.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(settings)
                .environmentObject(dictationEngine)
                .environmentObject(vocabManager)
                .environmentObject(hotkeyManager)
                .environmentObject(overlayController)
                .environmentObject(accessibilityManager)
        } label: {
            Label("VoiceFlow", systemImage: dictationEngine.isRecording ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        // Settings window (opened from menu bar).
        Settings {
            MacSettingsView()
                .environmentObject(settings)
                .environmentObject(dictationEngine)
                .environmentObject(vocabManager)
                .environmentObject(accessibilityManager)
        }
    }

    // Dock icon is hidden by LSUIElement=true in Info.plist.
    // Do NOT call NSApplication.shared.setActivationPolicy here —
    // NSApplication.shared isn't ready during App struct init and
    // it would crash on launch. LSUIElement is the correct, persistent
    // way to make a menu-bar-only app.
}

// MARK: - AppDelegate

/// Bridges AppKit lifecycle events. Handles cleanup on termination.
/// Dependency wiring happens in MenuBarView.onAppear since AppDelegate
/// can't access @StateObject properties from the App struct.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement=true in Info.plist already hides the Dock icon.
        // No programmatic setActivationPolicy needed — that's a temp
        // flag that doesn't persist and is the wrong approach.
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down the CGEvent tap so it doesn't leak across restarts.
        GlobalHotkeyManager.shared?.teardown()
    }
}
