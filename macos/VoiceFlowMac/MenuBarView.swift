//
//  MenuBarView.swift
//  VoiceFlowMac
//
//  SwiftUI view displayed in the MenuBarExtra dropdown. Provides:
//   - Start / Stop Dictation button
//   - Tone preset picker
//   - Status text (recording, polishing, idle)
//   - Recent polished text preview
//   - Settings (auto-clipboard toggle)
//   - Quit button
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: MacDictationEngine

    /// Manages the floating dictation panel lifecycle.
    @State private var floatingPanel: DictationFloatingPanel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(engine.isRecording ? .red : .accentColor)
                Text("VoiceFlow")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            Divider()

            // Start / Stop
            Button(action: toggleDictation) {
                Label(
                    engine.isRecording ? "Stop Dictation" : "Start Dictation",
                    systemImage: engine.isRecording ? "stop.circle.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(engine.isPolishing)

            Divider()

            // Tone picker
            Text("Tone")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Tone", selection: $engine.tonePreset) {
                ForEach(TonePreset.allCases) { preset in
                    Label(preset.title, systemImage: preset.symbolName)
                        .tag(preset)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            // Last result preview
            if !engine.polishedTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Result")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(engine.polishedTranscript)
                        .font(.callout)
                        .lineLimit(4)
                        .textSelection(.enabled)

                    Button("Copy to Clipboard") {
                        copyToClipboard(engine.polishedTranscript)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                Divider()
            }

            // Settings
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Auto-copy to clipboard", isOn: $engine.autoClipboard)

                Text("Global hotkey: \u{2318}\u{21E7}D")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Error display
            if let error = engine.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)

                Divider()
            }

            // Quit
            Button("Quit VoiceFlow") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var statusBadge: some View {
        if engine.isRecording {
            Text("Recording")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        } else if engine.isPolishing {
            Text("Polishing")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        } else {
            Text("Ready")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        }
    }

    private func toggleDictation() {
        if engine.isRecording {
            engine.stop()
            dismissFloatingPanel()
        } else {
            engine.start()
            showFloatingPanel()
        }
    }

    private func showFloatingPanel() {
        if floatingPanel == nil {
            floatingPanel = DictationFloatingPanel(engine: engine)
        }
        floatingPanel?.showPanel()
    }

    private func dismissFloatingPanel() {
        floatingPanel?.hidePanel()
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
