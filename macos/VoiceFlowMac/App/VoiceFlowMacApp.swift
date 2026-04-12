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
import Combine

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

    init() {
        // Hide Dock icon — menu-bar-only app.
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

// MARK: - AppDelegate

/// Bridges AppKit lifecycle events into our SwiftUI app. Primarily
/// used to wire up the global hotkey listener and manage the overlay
/// panel lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock (belt-and-suspenders with the init above).
        NSApp.setActivationPolicy(.accessory)

        // Wire dependencies after SwiftUI state objects are live.
        // We use a tiny delay to let @StateObject init complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.wireDependencies()
        }
    }

    private func wireDependencies() {
        // Access the shared instances through the SwiftUI app structure.
        // Since AppDelegate can't directly access @StateObject, we use
        // notification-based wiring — the actual wiring happens in the
        // MenuBarView's .onAppear.
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up the global event tap.
        GlobalHotkeyManager.shared?.teardown()
    }
}
