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
                Task { await engine.toggle() }
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

            // Last result preview
            if !engine.polishedTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Copied to clipboard:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(engine.polishedTranscript.prefix(200) +
                         (engine.polishedTranscript.count > 200 ? "..." : ""))
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            // Live transcript while recording
            if engine.isRecording && !engine.liveTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Listening:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(engine.liveTranscript.suffix(150))
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundColor(.primary)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            // Error display
            if let error = engine.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            // Accessibility warning
            if !hotkey.isAccessibilityGranted {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                    Text("Grant Accessibility permission for global hotkey.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .onTapGesture {
                    hotkey.checkAccessibilityPermission()
                }
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
            // Wire the hotkey to the engine's toggle.
            hotkey.onDoubleTap = {
                Task { @MainActor in
                    await engine.toggle()
                }
            }
            // Wire silence auto-stop.
            engine.onSilenceDetected = {
                Task { @MainActor in
                    await engine.stop()
                }
            }
        }
    }
}
