//
//  MenuBarView.swift
//  VoiceFlowMac
//
//  Simple dropdown from the menu bar icon. Shows:
//  - Start / Stop button
//  - Tone picker
//  - Last result preview (truncated)
//  - Error display
//  - Quit button
//

import SwiftUI

struct MenuBarView: View {

    @ObservedObject var engine: MacDictationEngine
    @ObservedObject var hotkey: GlobalHotkey

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Title row
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundColor(.accentColor)
                Text("VoiceFlow")
                    .font(.headline)
                Spacer()
                if engine.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8)
                        .frame(height: 8)
                }
            }

            Divider()

            // Start / Stop
            Button(action: {
                engine.toggle()
                // Return focus to the previous app so CGEvents
                // (live typing) go to the user's cursor, not here.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.hide(nil)
                }
            }) {
                HStack {
                    Image(systemName: engine.isRecording
                          ? "stop.circle.fill"
                          : "mic.circle.fill")
                    Text(engine.isRecording ? "Stop Dictation" : "Start Dictation")
                    Spacer()
                    Text("^^")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Tone picker
            HStack {
                Text("Tone:")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Picker("", selection: $engine.tonePreset) {
                    ForEach(TonePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            // Vocab packs (placeholder — packs loaded from iOS bundle)
            HStack {
                Text("Vocab:")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("General Business")
                    .font(.caption)
                    .foregroundColor(.primary)
                Spacer()
                Text("Edit…")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            }

            // Status
            if engine.isPolishing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cleaning up...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Status
            if engine.isRecording {
                Text("Recording — text appears at your cursor")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Error display
            if let error = engine.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            Divider()

            Button("Quit VoiceFlow") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            hotkey.onDoubleTap = { engine.toggle() }
            engine.onSilenceDetected = { engine.stop() }
        }
    }
}
