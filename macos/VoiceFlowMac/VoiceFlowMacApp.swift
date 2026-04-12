//
//  VoiceFlowMacApp.swift
//  VoiceFlowMac
//
//  Menu-bar-only macOS companion app for VoiceFlow. No dock icon.
//  Uses MenuBarExtra (macOS 13+) to anchor a dropdown in the status
//  bar. A floating NSPanel shows the live transcript while dictating.
//

import SwiftUI

@main
struct VoiceFlowMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = MacDictationEngine()
    @StateObject private var hotkeyManager = GlobalHotkeyManager()

    var body: some Scene {
        // MenuBarExtra provides the status-bar icon + dropdown.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(engine)
                .task {
                    // Wire the hotkey to the engine once the view is up.
                    hotkeyManager.engine = engine
                }
        } label: {
            // Use waveform (not mic) so it doesn't clash with macOS's
            // own speech-recognition mic indicator in the menu bar.
            Image(systemName: engine.isRecording ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate (hide dock icon)

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon. LSUIElement in Info.plist also does this
        // but setting it here ensures it works even if Info.plist is
        // missing the key during development.
        NSApp.setActivationPolicy(.accessory)
    }
}
