//
//  MacAppSettings.swift
//  VoiceFlowMac
//
//  Persistent settings for the macOS app. All stored in UserDefaults.
//

import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class MacAppSettings: ObservableObject {

    // MARK: - Keys

    private enum Keys {
        static let silenceAutoStopSeconds = "VoiceFlowMac.settings.silenceAutoStopSeconds"
        static let autoInsertAfterPolish = "VoiceFlowMac.settings.autoInsertAfterPolish"
        static let showOverlayDuringDictation = "VoiceFlowMac.settings.showOverlayDuringDictation"
        static let launchAtLogin = "VoiceFlowMac.settings.launchAtLogin"
        static let playSoundEffects = "VoiceFlowMac.settings.playSoundEffects"
        static let hotkeyDoubleTapSpeed = "VoiceFlowMac.settings.hotkeyDoubleTapSpeed"
    }

    // MARK: - Published

    /// Seconds of trailing silence before auto-stopping dictation.
    @Published var silenceAutoStopSeconds: Double {
        didSet { UserDefaults.standard.set(silenceAutoStopSeconds, forKey: Keys.silenceAutoStopSeconds) }
    }

    /// Automatically insert polished text at cursor when cleanup finishes.
    @Published var autoInsertAfterPolish: Bool {
        didSet { UserDefaults.standard.set(autoInsertAfterPolish, forKey: Keys.autoInsertAfterPolish) }
    }

    /// Show the floating overlay panel during dictation.
    @Published var showOverlayDuringDictation: Bool {
        didSet { UserDefaults.standard.set(showOverlayDuringDictation, forKey: Keys.showOverlayDuringDictation) }
    }

    /// Launch VoiceFlow at login.
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    /// Play sound effects on start/stop/complete.
    @Published var playSoundEffects: Bool {
        didSet { UserDefaults.standard.set(playSoundEffects, forKey: Keys.playSoundEffects) }
    }

    /// Double-tap speed threshold for the Control hotkey (seconds).
    /// Lower = faster double-tap required. Range: 0.2 ... 0.6.
    @Published var hotkeyDoubleTapSpeed: Double {
        didSet { UserDefaults.standard.set(hotkeyDoubleTapSpeed, forKey: Keys.hotkeyDoubleTapSpeed) }
    }

    // MARK: - Init

    init() {
        let d = UserDefaults.standard

        let silence = d.double(forKey: Keys.silenceAutoStopSeconds)
        self.silenceAutoStopSeconds = silence > 0 ? silence : 2.0

        if d.object(forKey: Keys.autoInsertAfterPolish) == nil {
            self.autoInsertAfterPolish = true
        } else {
            self.autoInsertAfterPolish = d.bool(forKey: Keys.autoInsertAfterPolish)
        }

        if d.object(forKey: Keys.showOverlayDuringDictation) == nil {
            self.showOverlayDuringDictation = true
        } else {
            self.showOverlayDuringDictation = d.bool(forKey: Keys.showOverlayDuringDictation)
        }

        self.launchAtLogin = d.bool(forKey: Keys.launchAtLogin)

        if d.object(forKey: Keys.playSoundEffects) == nil {
            self.playSoundEffects = true
        } else {
            self.playSoundEffects = d.bool(forKey: Keys.playSoundEffects)
        }

        let tapSpeed = d.double(forKey: Keys.hotkeyDoubleTapSpeed)
        self.hotkeyDoubleTapSpeed = tapSpeed > 0 ? tapSpeed : 0.4
    }

    // MARK: - Login item

    private func updateLoginItem() {
        if #available(macOS 13.0, *) {
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }
}
