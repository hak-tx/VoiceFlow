//
//  VoiceFlowMacApp.swift
//  VoiceFlowMac
//
//  Menu-bar-only macOS app. No dock icon.
//

import SwiftUI

@main
struct VoiceFlowMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = MacDictationEngine()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(engine)
        } label: {
            Image(systemName: engine.isRecording ? "v.circle.fill" : "v.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
