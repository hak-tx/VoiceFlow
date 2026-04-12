//
//  MenuBarView.swift
//  VoiceFlowMac
//
//  The primary UI surface — a popover window from the menu bar icon.
//  Shows:
//    - Current state (idle / recording / polishing / done)
//    - Tone preset quick-switcher
//    - Active vocab packs summary
//    - Last transcript (editable after polish)
//    - Action buttons (Copy, Clear, Re-dictate selection, etc.)
//    - Quick links to Settings and Quit
//
//  The entire dictation lifecycle can be controlled from here, but
//  the primary workflow is the global ⌃⌃ hotkey which triggers
//  dictation without opening this popover.
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var engine: MacDictationEngine
    @EnvironmentObject var vocabManager: MacVocabPackManager
    @EnvironmentObject var hotkeyManager: GlobalHotkeyManager
    @EnvironmentObject var overlayController: OverlayPanelController
    @EnvironmentObject var accessibilityManager: AccessibilityTextManager

    @State private var showingVocabPicker = false
    @State private var showingTonePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Tone quick-switcher
            toneRow
            Divider()

            // Transcript area
            transcriptArea

            Divider()

            // Action bar
            actionBar

            Divider()

            // Footer controls
            footerControls
        }
        .frame(width: 380)
        .onAppear {
            wireDependencies()
        }
    }

    // MARK: - Wiring

    private func wireDependencies() {
        // Wire engine dependencies.
        engine.vocabManager = vocabManager
        engine.settings = settings
        engine.silenceThreshold = settings.silenceAutoStopSeconds

        // Wire hotkey callbacks.
        hotkeyManager.onActivate = { [weak engine, weak accessibilityManager, weak overlayController, weak settings] in
            guard let engine, let accessibilityManager, let overlayController, let settings else { return }
            Task { @MainActor in
                // Snapshot what's at the cursor before we start.
                accessibilityManager.captureCurrentContext()

                // If there's selected text, enter replace mode.
                if !accessibilityManager.selectedText.isEmpty {
                    let ctx = accessibilityManager.surroundingContext()
                    let range = NSRange(
                        location: accessibilityManager.selectedRange.location,
                        length: accessibilityManager.selectedRange.length
                    )
                    await engine.startReplacingSelection(
                        in: accessibilityManager.fullText,
                        range: range,
                        before: ctx.before,
                        after: ctx.after
                    )
                } else {
                    await engine.start()
                }

                // Show the overlay near the cursor.
                overlayController.show(
                    near: accessibilityManager.cursorRect,
                    engine: engine,
                    settings: settings
                )
            }
        }

        hotkeyManager.onDeactivate = { [weak engine, weak overlayController, weak accessibilityManager, weak settings] in
            guard let engine, let overlayController else { return }
            Task { @MainActor in
                await engine.stop()

                // Wait briefly for polish to complete, then insert.
                // The onPolishComplete callback handles the actual insertion.
            }
        }

        // When polish completes, insert at cursor and dismiss overlay.
        engine.onPolishComplete = { [weak accessibilityManager, weak overlayController, weak hotkeyManager, weak settings] text in
            Task { @MainActor in
                guard let accessibilityManager, let overlayController, let settings else { return }

                if settings.autoInsertAfterPolish {
                    accessibilityManager.insertText(text)
                } else {
                    // Just copy to clipboard.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }

                // Play completion sound.
                if settings.playSoundEffects {
                    NSSound(named: "Blow")?.play()
                }

                // Brief delay so the user sees "DONE" in the overlay.
                try? await Task.sleep(nanoseconds: 800_000_000)
                overlayController.dismiss()
                hotkeyManager?.deactivate()
            }
        }

        // Silence auto-stop.
        engine.onSilenceDetected = { [weak engine] in
            Task { @MainActor in
                await engine?.stop()
            }
        }

        // Install the global hotkey listener.
        hotkeyManager.install()

        // Load vocab packs.
        Task {
            await vocabManager.loadInstalledPacks()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("VoiceFlow")
                    .font(.system(size: 14, weight: .bold))

                HStack(spacing: 4) {
                    Circle()
                        .fill(hotkeyManager.hasAccessibilityPermission ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text(hotkeyManager.hasAccessibilityPermission
                         ? "Ready — ⌃⌃ to dictate"
                         : "Accessibility permission needed")
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
                        .opacity(0.8)
                    Text("Recording")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

            if engine.visibleTranscript.isEmpty && !engine.isRecording {
                Text("Press ⌃⌃ (Control twice) to start dictating.\nText appears here and inserts at your cursor.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
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
                        await engine.stop()
                    } else {
                        accessibilityManager.captureCurrentContext()
                        if !accessibilityManager.selectedText.isEmpty {
                            let ctx = accessibilityManager.surroundingContext()
                            let range = NSRange(
                                location: accessibilityManager.selectedRange.location,
                                length: accessibilityManager.selectedRange.length
                            )
                            await engine.startReplacingSelection(
                                in: accessibilityManager.fullText,
                                range: range,
                                before: ctx.before,
                                after: ctx.after
                            )
                        } else {
                            await engine.start()
                        }
                    }
                }
            } label: {
                Image(systemName: engine.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(engine.isRecording ? .red : .accentColor)
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
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
