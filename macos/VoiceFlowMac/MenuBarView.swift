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

    /// All available vocab packs.
    private let allPacks = [
        "Software Dev", "General Business", "Medical General",
        "Corporate Law", "Real Estate", "Construction",
        "Finance & Banking", "Marketing & Advertising",
        "Management Consulting", "Healthcare Nursing",
        "Accounting & Tax"
    ]

    @State private var activePacks: Set<String> = ["General Business"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Title
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("VoiceFlow")
                    .font(.title3.bold())
                Spacer()
                if engine.isRecording {
                    Circle().fill(Color.red)
                        .frame(width: 10, height: 10)
                }
            }

            Divider()

            // Start / Stop
            Button(action: {
                engine.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.hide(nil)
                }
            }) {
                HStack {
                    Image(systemName: engine.isRecording
                          ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title3)
                    Text(engine.isRecording ? "Stop Dictation" : "Start Dictation")
                        .font(.body.bold())
                    Spacer()
                    Text("⌃⌃")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            Divider()

            // Tone
            HStack {
                Text("Tone")
                    .font(.body.bold())
                Spacer()
                Picker("", selection: $engine.tonePreset) {
                    ForEach(TonePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            // Vocab Packs
            VStack(alignment: .leading, spacing: 8) {
                Text("Industry Vocab Packs")
                    .font(.body.bold())

                ForEach(allPacks, id: \.self) { pack in
                    Button(action: {
                        if activePacks.contains(pack) {
                            activePacks.remove(pack)
                        } else {
                            activePacks.insert(pack)
                        }
                    }) {
                        HStack {
                            Image(systemName: activePacks.contains(pack)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundColor(activePacks.contains(pack)
                                                 ? .accentColor : .secondary)
                            Text(pack)
                                .font(.body)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Status
            if engine.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Recording — text appears at your cursor")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }

            if engine.isPolishing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cleaning up with Claude...")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }

            if let error = engine.errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            Divider()

            Button("Quit VoiceFlow") {
                NSApplication.shared.terminate(nil)
            }
            .font(.body)
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            hotkey.onDoubleTap = { engine.toggle() }
            engine.onSilenceDetected = { engine.stop() }
        }
    }
}
