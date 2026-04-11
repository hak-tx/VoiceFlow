//
//  AppSettings.swift
//  VoiceFlow
//
//  Global, non-domain settings: Discreet Mode, silence auto-stop
//  threshold, whether onboarding has been completed, preferred
//  color scheme, etc. All persisted in UserDefaults.
//

import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Keys

    private enum Keys {
        static let discreetMode = "VoiceFlow.settings.discreetMode"
        static let onboardingDone = "VoiceFlow.settings.onboardingDone"
        static let silenceAutoStopSeconds = "VoiceFlow.settings.silenceAutoStopSeconds"
        static let autoCopyAfterQuickDictate = "VoiceFlow.settings.autoCopyAfterQuickDictate"
    }

    // MARK: - Published

    /// Discreet Mode: monochrome alternate app icon, subdued
    /// palette, dark-mode default. Designed for corporate phones
    /// where a flashy icon would stand out.
    @Published var discreetMode: Bool {
        didSet {
            UserDefaults.standard.set(discreetMode, forKey: Keys.discreetMode)
            applyAlternateIconIfNeeded()
        }
    }

    /// Whether the first-launch onboarding has been completed.
    @Published var onboardingDone: Bool {
        didSet {
            UserDefaults.standard.set(onboardingDone, forKey: Keys.onboardingDone)
        }
    }

    /// Seconds of trailing silence before Quick Dictate auto-stops.
    /// Exposed as a slider in Settings (1.0 ... 5.0).
    @Published var silenceAutoStopSeconds: Double {
        didSet {
            UserDefaults.standard.set(silenceAutoStopSeconds, forKey: Keys.silenceAutoStopSeconds)
        }
    }

    /// Whether Quick Dictate auto-copies the polished transcript to
    /// UIPasteboard when cleanup completes. On by default — this is
    /// the whole product thesis.
    @Published var autoCopyAfterQuickDictate: Bool {
        didSet {
            UserDefaults.standard.set(autoCopyAfterQuickDictate, forKey: Keys.autoCopyAfterQuickDictate)
        }
    }

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        self.discreetMode = d.bool(forKey: Keys.discreetMode)
        self.onboardingDone = d.bool(forKey: Keys.onboardingDone)
        let raw = d.double(forKey: Keys.silenceAutoStopSeconds)
        self.silenceAutoStopSeconds = raw > 0 ? raw : 2.0
        if d.object(forKey: Keys.autoCopyAfterQuickDictate) == nil {
            self.autoCopyAfterQuickDictate = true
        } else {
            self.autoCopyAfterQuickDictate = d.bool(forKey: Keys.autoCopyAfterQuickDictate)
        }
    }

    // MARK: - Theming

    /// Suggested preferred color scheme based on Discreet Mode. Used
    /// at the root view with `.preferredColorScheme(_:)`.
    var preferredColorScheme: ColorScheme? {
        discreetMode ? .dark : nil
    }

    // MARK: - Alternate icon

    /// Name of the alternate icon asset to use when Discreet Mode is
    /// on. Set in Info.plist under CFBundleIcons →
    /// CFBundleAlternateIcons.
    static let discreetIconName = "AppIcon-Discreet"

    private func applyAlternateIconIfNeeded() {
        let target: String? = discreetMode ? Self.discreetIconName : nil
        // `setAlternateIconName` is a no-op when the app isn't
        // registered for alternate icons yet. Wrap defensively so
        // pre-icon builds don't crash.
        guard UIApplication.shared.supportsAlternateIcons else { return }
        if UIApplication.shared.alternateIconName != target {
            UIApplication.shared.setAlternateIconName(target) { _ in
                // Intentionally swallow errors; most common error is
                // "no alternate icon configured" which we can't fix
                // at runtime anyway.
            }
        }
    }
}
