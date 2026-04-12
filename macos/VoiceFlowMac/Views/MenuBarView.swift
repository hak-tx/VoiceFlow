//
//  MenuBarView.swift
//  VoiceFlowMac
//
//  The primary UI surface — a popover window from the menu bar icon.
//  This is a PURE VIEW — it reads state from environment objects and
//  dispatches actions to the AppCoordinator. No wiring happens here.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.hak-tx.voiceflow.mac", category: "MenuBarView")

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var engine: MacDictationEngine
    @EnvironmentObject var vocabManager: MacVocabPackManager
    @EnvironmentObject var hotkeyManager: GlobalHotkeyManager
    @EnvironmentObject var accessibilityManager: AccessibilityTextManager

    @State private var showingVocabPicker = false
    @State private var apiKeyInput: String = ""
    @State private var apiKeyConfigured: Bool = Secrets.isAPIKeyConfigured

    var body: some View {
        VStack(spacing: 0) {
            header

            // Setup prompts — always show until both are done
            if !apiKeyConfigured || !hotkeyManager.hasAccessibilityPermission {
                Divider()
                setupPrompts
            }

            Divider()
            toneRow
            Divider()
            footerControls
        }
        .frame(width: 380)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("VoiceFlow")
                    .font(.system(size: 14, weight: .bold))

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if engine.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulsingAnimation)
                    Text("Recording")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @State private var pulsingAnimation: Double = 0.8

    private var statusColor: Color {
        if !hotkeyManager.hasAccessibilityPermission { return .red }
        if engine.isRecording { return .orange }
        if engine.errorMessage != nil { return .red }
        return .green
    }

    private var statusMessage: String {
        if !hotkeyManager.hasAccessibilityPermission {
            return "Accessibility permission needed"
        }
        if let error = engine.errorMessage {
            return error
        }
        if engine.isRecording { return "Recording — ⌃⌃ to stop" }
        if engine.isPolishing { return "Cleaning up with Claude..." }
        return "Ready — ⌃⌃ to dictate"
    }

    // MARK: - Setup prompts

    private var setupPrompts: some View {
        VStack(alignment: .leading, spacing: 8) {
            // API Key
            if !apiKeyConfigured {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                        Text("Anthropic API Key")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("Copy your API key, then click the button below.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button {
                        if let clipboardText = NSPasteboard.general.string(forType: .string)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !clipboardText.isEmpty {
                            Secrets.saveAPIKey(clipboardText)
                            apiKeyConfigured = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste API Key from Clipboard")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }

            // Accessibility
            if !hotkeyManager.hasAccessibilityPermission {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                    Text("Accessibility permission needed for ⌃⌃ hotkey")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Grant") {
                        hotkeyManager.requestAccessibilityPermission()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.05))
    }

    // MARK: - Tone row

    private var toneRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("TONE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(1)

                ForEach(TonePreset.allCases) { preset in
                    toneChip(preset)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func toneChip(_ preset: TonePreset) -> some View {
        let isActive = engine.tonePreset == preset

        Button {
            engine.tonePreset = preset
        } label: {
            HStack(spacing: 3) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                Text(preset.title)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footerControls: some View {
        HStack {
            Button {
                showingVocabPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 10))
                    Text("Vocab Packs")
                        .font(.system(size: 10))
                    if !vocabManager.activePackNames.isEmpty {
                        Text("(\(vocabManager.activePackNames.count))")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingVocabPicker) {
                MacVocabPackPickerView()
                    .environmentObject(vocabManager)
                    .frame(width: 340, height: 400)
            }

            Spacer()

            if !hotkeyManager.hasAccessibilityPermission {
                Button("Grant Access") {
                    hotkeyManager.requestAccessibilityPermission()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
            }

            if #available(macOS 14.0, *) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Settings")
            } else {
                Button {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Settings")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit VoiceFlow")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

