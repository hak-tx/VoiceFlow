//
//  VoiceFlowMacApp.swift
//  VoiceFlowMac
//
//  macOS menu-bar app entry point. VoiceFlow lives in the menu bar
//  with no Dock icon (LSUIElement=true in Info.plist). The user
//  triggers dictation system-wide via a double-Control (⌃⌃) hotkey.
//
//  All dependency wiring happens in AppCoordinator.setup(), which
//  runs exactly once. Views receive managers via @EnvironmentObject.
//

import SwiftUI

@main
struct VoiceFlowMacApp: App {

    /// Single coordinator that owns all managers and wires them together.
    @StateObject private var coordinator = AppCoordinator()

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar extra — the only visible chrome when idle.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.settings)
                .environmentObject(coordinator.engine)
                .environmentObject(coordinator.vocabManager)
                .environmentObject(coordinator.hotkeyManager)
                .environmentObject(coordinator.overlayController)
                .environmentObject(coordinator.accessibilityManager)
                .task {
                    // Runs once when the MenuBarExtra is first created.
                    coordinator.setup()
                }
        } label: {
            Label("VoiceFlow", systemImage: coordinator.engine.isRecording ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        // Settings window (opened from menu bar).
        Settings {
            MacSettingsView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.settings)
                .environmentObject(coordinator.engine)
                .environmentObject(coordinator.vocabManager)
                .environmentObject(coordinator.accessibilityManager)
        }
    }

    // Dock icon is hidden by LSUIElement=true in Info.plist.
    // Do NOT call NSApplication.shared.setActivationPolicy here —
    // NSApplication.shared isn't ready during App struct init.
}

// MARK: - AppDelegate

/// Handles AppKit lifecycle events. Dependency wiring is in
/// AppCoordinator — AppDelegate only handles cleanup.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement=true in Info.plist hides the Dock icon.
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared?.teardown()
    }
}
