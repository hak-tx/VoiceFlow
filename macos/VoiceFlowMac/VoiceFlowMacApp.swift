//
//  VoiceFlowMacApp.swift
//  VoiceFlowMac
//
//  Menu-bar-only macOS companion for VoiceFlow. No dock icon
//  (LSUIElement = true in Info.plist). Double-tap Control to
//  toggle dictation globally.
//

import SwiftUI

@main
struct VoiceFlowMacApp: App {

    @StateObject private var engine = MacDictationEngine()
    @StateObject private var hotkey = GlobalHotkey()

    var body: some Scene {
        MenuBarExtra("VoiceFlow", systemImage: "waveform.circle") {
            MenuBarView(engine: engine, hotkey: hotkey)
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        // Wire up hotkey -> engine toggle after both are created.
        // We use a slight delay because @StateObject init runs
        // lazily; the real wiring happens in MenuBarView.onAppear.
    }
}
