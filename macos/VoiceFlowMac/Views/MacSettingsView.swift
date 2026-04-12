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
import Speech
import AVFoundation
import Combine

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
                            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
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
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
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

    @State private var apiKeyInput: String = ""
    @State private var isKeyConfigured: Bool = Secrets.isAPIKeyConfigured
    @State private var showingSaveConfirmation = false

    var body: some View {
        VStack(spacing: 16) {
            // App info
            HStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("VoiceFlow for Mac")
                        .font(.title3.bold())
                    Text("Dictate anywhere. Claude cleans it up.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text("Version 1.0.0")
                        Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Divider()

            // API Key configuration — this is the critical setup step
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: isKeyConfigured ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .foregroundStyle(isKeyConfigured ? .green : .orange)
                            Text(isKeyConfigured ? "API key configured" : "API key required")
                                .font(.system(size: 13, weight: .medium))
                        }

                        Text("VoiceFlow uses the Anthropic API (Claude Haiku) to clean up your dictation. Enter your API key below. It's stored securely in your Mac's Keychain — never in plain text.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack {
                            SecureField("sk-ant-api03-...", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))

                            Button(isKeyConfigured ? "Update" : "Save") {
                                let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                Secrets.saveAPIKey(trimmed)
                                isKeyConfigured = Secrets.isAPIKeyConfigured
                                apiKeyInput = ""
                                showingSaveConfirmation = true
                            }
                            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .controlSize(.small)
                        }

                        if showingSaveConfirmation {
                            Text("Key saved to Keychain.")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                                .task {
                                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                                    showingSaveConfirmation = false
                                }
                        }
                    }
                } header: {
                    Text("Anthropic API Key")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        infoRow("Model", value: "Claude Haiku 4.5")
                        infoRow("Keychain", value: "com.hak-tx.voiceflow.mac")
                        infoRow("Speech", value: "On-device (Apple)")
                    }
                } header: {
                    Text("Technical Details")
                } footer: {
                    Text("All speech recognition runs locally on your Mac. Only the transcript text is sent to the Claude API for cleanup — no audio ever leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)
        }
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
