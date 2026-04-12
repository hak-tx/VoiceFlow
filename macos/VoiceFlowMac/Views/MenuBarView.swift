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
    @State private var showingAPIKeyField = false

    var body: some View {
        VStack(spacing: 0) {
            header

            // Setup prompts — show until configured
            if !Secrets.isAPIKeyConfigured || !hotkeyManager.hasAccessibilityPermission {
                Divider()
                setupPrompts
            }

            Divider()
            toneRow
            Divider()
            transcriptArea
            Divider()
            actionBar
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
            if !Secrets.isAPIKeyConfigured {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                        Text("Enter your Anthropic API key:")
                            .font(.system(size: 11, weight: .medium))
                    }
                    HStack(spacing: 6) {
                        SecureField("sk-ant-api03-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Save") {
                            let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            Secrets.saveAPIKey(trimmed)
                            apiKeyInput = ""
                        }
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
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

    // MARK: - Transcript

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if engine.isRecording {
                WaveformBar(level: engine.audioLevel)
                    .frame(height: 16)
                    .padding(.horizontal, 14)
            }

            if engine.visibleTranscript.isEmpty && !engine.isRecording && !engine.isPolishing {
                VStack(spacing: 8) {
                    Text("Press ⌃⌃ (Control twice) to start dictating.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("Text appears here and inserts at your cursor.")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    Text(engine.visibleTranscript.isEmpty ? "Listening..." : engine.visibleTranscript)
                        .font(.system(size: 12))
                        .foregroundStyle(engine.visibleTranscript.isEmpty ? .tertiary : .primary)
                        .italic(engine.visibleTranscript.isEmpty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(.horizontal, 14)

                if engine.isPolishing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Cleaning up with Claude...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                }

                // Error + retry
                if let error = coordinator.lastPolishError {
                    VStack(spacing: 4) {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Button("Retry Cleanup") {
                            Task { await coordinator.retryPolish() }
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 6) {
            MenuActionButton(title: "Copy", systemImage: "doc.on.doc") {
                let text = engine.visibleTranscript
                guard !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(engine.visibleTranscript.isEmpty)

            MenuActionButton(title: "Clear", systemImage: "xmark.circle") {
                engine.clearBuffers()
                coordinator.lastPolishError = nil
            }
            .disabled(engine.visibleTranscript.isEmpty)

            MenuActionButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                engine.revertToRaw()
            }
            .disabled(engine.polishedTranscript.isEmpty || engine.isRecording)

            MenuActionButton(title: "Redo", systemImage: "arrow.uturn.forward") {
                engine.redoPolish()
            }
            .disabled(!engine.polishedTranscript.isEmpty || engine.cachedPolishedTranscript.isEmpty)

            Spacer()

            // Manual start/stop button.
            Button {
                Task {
                    if engine.isRecording {
                        await coordinator.stopDictationManually()
                    } else {
                        await coordinator.startDictationManually()
                    }
                }
            } label: {
                Image(systemName: engine.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(engine.isRecording ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(engine.isRecording ? "Stop dictation" : "Start dictation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

            Button {
                // Activate the app first, then open Settings.
                // MenuBarExtra popovers can't send actions without this.
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Settings")

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

// MARK: - MenuActionButton

private struct MenuActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(width: 44, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}
