//
//  MacSettingsView.swift
//  VoiceFlowMac
//
//  macOS Settings window. Uses TabView for organized sections.
//  Large, clear dropdown pickers similar to the iOS app's UX.
//
//  Tabs:
//    - General: hotkey, auto-insert, silence threshold, sounds
//    - Cleanup: tone preset, vocab packs
//    - Permissions: accessibility status, microphone, speech
//    - About: version, API key status
//

import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            CleanupSettingsTab()
                .tabItem {
                    Label("Cleanup", systemImage: "sparkles")
                }

            PermissionsSettingsTab()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: MacAppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // Hotkey info
                    HStack(spacing: 12) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                            .frame(width: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Global Hotkey")
                                .font(.headline)
                            Text("Press Control (⌃) twice quickly to start/stop dictation from anywhere.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Double-tap speed") {
                        HStack {
                            Slider(
                                value: $settings.hotkeyDoubleTapSpeed,
                                in: 0.2...0.6,
                                step: 0.05
                            )
                            .frame(width: 160)
                            Text("\(Int(settings.hotkeyDoubleTapSpeed * 1000))ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Hotkey")
            }

            Section {
                LabeledContent("Silence auto-stop") {
                    HStack {
                        Slider(
                            value: $settings.silenceAutoStopSeconds,
                            in: 1.0...5.0,
                            step: 0.5
                        )
                        .frame(width: 160)
                        Text("\(String(format: "%.1f", settings.silenceAutoStopSeconds))s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                }

                Toggle("Auto-insert at cursor after cleanup", isOn: $settings.autoInsertAfterPolish)

                Toggle("Show floating overlay during dictation", isOn: $settings.showOverlayDuringDictation)

                Toggle("Play sound effects", isOn: $settings.playSoundEffects)
            } header: {
                Text("Dictation")
            }

            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Cleanup

struct CleanupSettingsTab: View {
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var engine: MacDictationEngine
    @EnvironmentObject var vocabManager: MacVocabPackManager

    @State private var showingCustomVocabEditor = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tone Preset")
                        .font(.headline)
                    Text("Controls how aggressively Claude rewrites your transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Large dropdown picker — similar to iOS experience.
                    Picker("", selection: $engine.tonePreset) {
                        ForEach(TonePreset.allCases) { preset in
                            HStack(spacing: 8) {
                                Image(systemName: preset.symbolName)
                                    .frame(width: 20)
                                VStack(alignment: .leading) {
                                    Text(preset.title)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(preset.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(preset)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            } header: {
                Text("Tone")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Active Vocab Packs")
                            .font(.headline)
                        Spacer()
                        Text("\(vocabManager.activePackNames.count) active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if vocabManager.installedPacks.isEmpty {
                        Text("No packs installed. Open the Vocab Packs picker from the menu bar.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(vocabManager.installedPacks) { pack in
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { vocabManager.activePackNames.contains(pack.name) },
                                    set: { _ in vocabManager.toggleActive(pack.name) }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(pack.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Text("\(pack.terms.count) terms")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Button("Edit Custom Vocabulary...") {
                    showingCustomVocabEditor = true
                }
            } header: {
                Text("Vocabulary")
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingCustomVocabEditor) {
            MacCustomVocabEditor()
                .environmentObject(vocabManager)
        }
        .task {
            await vocabManager.loadInstalledPacks()
        }
    }
}

// MARK: - Permissions

struct PermissionsSettingsTab: View {
    @EnvironmentObject var accessibilityManager: AccessibilityTextManager

    @State private var accessibilityGranted = false
    @State private var microphoneGranted = false
    @State private var speechGranted = false

    /// Timer to re-check permissions while this tab is visible.
    /// macOS has no notification when the user toggles a permission
    /// in System Settings, so we poll (same as Alfred, Raycast, etc.).
    let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Accessibility",
                    description: "Required for the global ⌃⌃ hotkey and inserting text at your cursor. This permission is permanent once granted — it persists across reboots and app updates.",
                    granted: accessibilityGranted,
                    action: {
                        // Opens System Settings → Privacy & Security →
                        // Accessibility with VoiceFlow highlighted.
                        let _ = AXIsProcessTrustedWithOptions(
                            [kAXTrustedCheckOptionPrompt: true] as CFDictionary
                        )
                    }
                )

                PermissionRow(
                    title: "Microphone",
                    description: "Required to capture your voice for dictation. Granted via the standard macOS permission dialog.",
                    granted: microphoneGranted,
                    action: {
                        Task {
                            if #available(macOS 14.0, *) {
                                _ = await AVAudioApplication.requestRecordPermission()
                            }
                            checkPermissions()
                        }
                    }
                )

                PermissionRow(
                    title: "Speech Recognition",
                    description: "Required to transcribe your speech in real time. Uses on-device Apple Speech Recognition.",
                    granted: speechGranted,
                    action: {
                        SFSpeechRecognizer.requestAuthorization { _ in
                            DispatchQueue.main.async { checkPermissions() }
                        }
                    }
                )
            } header: {
                Text("Required Permissions")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All speech recognition runs locally on your Mac. Only the final transcript text is sent to the Claude API for cleanup — no audio ever leaves your device.")
                    Text("Permissions are stored by macOS and persist permanently. You can revoke them at any time in System Settings → Privacy & Security.")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            checkPermissions()
        }
        .onReceive(permissionTimer) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        accessibilityGranted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt: false] as CFDictionary
        )

        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: microphoneGranted = true
            default: microphoneGranted = false
            }
        } else {
            microphoneGranted = true
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechGranted = true
        default: speechGranted = false
        }
    }
}

import Speech
import AVFoundation

private struct PermissionRow: View {
    let title: String
    let description: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(granted ? .green : .orange)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant") {
                    action()
                }
                .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - About

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.accentColor)

            Text("VoiceFlow for Mac")
                .font(.title2.bold())

            Text("Dictate anywhere. Claude cleans it up.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 6) {
                infoRow("Version", value: "1.0.0")
                infoRow("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                infoRow("API Key", value: Secrets.anthropicAPIKey == "sk-ant-REPLACE-ME" ? "Not configured" : "Configured")
                infoRow("Model", value: "Claude Haiku 4.5")
            }

            Spacer()

            Text("VoiceFlow uses the Anthropic API for text cleanup.\nAll speech recognition runs locally on your Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
        .font(.system(size: 12))
    }
}
