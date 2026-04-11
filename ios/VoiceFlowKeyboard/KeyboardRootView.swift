//
//  KeyboardRootView.swift
//  VoiceFlowKeyboard
//
//  SwiftUI root view hosted inside UIInputViewController. Keyboard
//  extensions have tight screen real estate (default height ~260pt)
//  so the layout is minimal:
//
//    ┌────────────────────────────────┐
//    │ [Verbatim v]           [🌐]    │  ← top bar
//    │                                │
//    │         ┌──────┐               │
//    │         │  🎤  │               │  ← big mic
//    │         └──────┘               │
//    │                                │
//    │  "listening…" / transcript     │
//    └────────────────────────────────┘
//
//  When the user has not enabled Full Access, we show an explainer
//  instead of the mic, pointing them to Settings.
//

import SwiftUI

struct KeyboardRootView: View {
    @ObservedObject var engine: VoiceFlowKeyboardEngine
    let hasFullAccess: Bool

    @State private var showingTonePicker = false

    var body: some View {
        if !hasFullAccess {
            fullAccessExplainer
        } else {
            mainKeyboard
        }
    }

    // MARK: - Main keyboard layout

    private var mainKeyboard: some View {
        VStack(spacing: 8) {
            topBar
            Spacer(minLength: 4)
            micButton
            transcriptLine
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
    }

    private var topBar: some View {
        HStack {
            // Tone picker button.
            Menu {
                ForEach(TonePreset.allCases) { preset in
                    Button {
                        engine.tonePreset = preset
                    } label: {
                        HStack {
                            Image(systemName: preset.symbolName)
                            Text(preset.title)
                            if engine.tonePreset == preset {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: engine.tonePreset.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(engine.tonePreset.title)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                )
            }

            Spacer()

            // Globe key to switch keyboards.
            Button {
                engine.requestKeyboardSwitch()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
        }
    }

    private var micButton: some View {
        Button {
            engine.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(engine.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 88, height: 88)
                    .shadow(radius: engine.isRecording ? 6 : 3)

                if engine.isPolishing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                } else {
                    Image(systemName: engine.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(engine.isRecording ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: engine.isRecording)
    }

    private var transcriptLine: some View {
        Text(currentStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 8)
    }

    private var currentStatus: String {
        if engine.isPolishing { return "Cleaning up…" }
        if engine.isRecording {
            return engine.liveTranscript.isEmpty ? "Listening…" : engine.liveTranscript
        }
        return "Tap mic to dictate"
    }

    // MARK: - Full Access explainer

    private var fullAccessExplainer: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
            Text("Enable Full Access")
                .font(.subheadline.weight(.semibold))
            Text("VoiceFlow needs Full Access to send your speech to Claude for cleanup. Settings → General → Keyboard → Keyboards → VoiceFlow → Allow Full Access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .background(Color(.systemGray6))
    }
}
