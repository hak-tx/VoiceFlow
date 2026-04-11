//
//  QuickDictateView.swift
//  VoiceFlow
//
//  The hero experience: one-shot dictation that goes from button
//  press to a polished transcript on the clipboard in under 5
//  seconds. Triggered from the Action Button, Lock Screen,
//  Control Center, Siri, Shortcuts, or the in-app Quick Dictate
//  button.
//
//  Interaction model:
//   - On appear: immediately start recording with silence auto-stop.
//   - While recording: full-screen minimal UI with an animated
//     waveform driven by DictationEngine.audioLevel, the streaming
//     transcript, and a single big "Done" tap target.
//   - Stop triggers: user taps anywhere, OR configurable silence
//     threshold (default 2.0s) elapses with no speech, OR a hard
//     60s cap (belt-and-suspenders).
//   - On stop: run cleanup, auto-copy to UIPasteboard, save to
//     history, fire success haptic.
//   - Confirmation banner: shows a checkmark + first 60 chars of
//     polished text + up to 4 configured paste-target icons for
//     "open <app>" one-taps. Auto-dismisses after 2s unless the
//     user is interacting.
//

import SwiftUI
import UIKit

struct QuickDictateView: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var vocabManager: VocabPackManager
    @EnvironmentObject var history: DictationHistoryStore
    @EnvironmentObject var pasteTargets: PasteTargetsManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .recording
    @State private var polishedPreview: String = ""

    enum Phase {
        case recording
        case polishing
        case confirmed
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                topBar

                Spacer()

                switch phase {
                case .recording:
                    recordingStack
                case .polishing:
                    polishingStack
                case .confirmed:
                    confirmationStack
                }

                Spacer()

                if phase == .recording {
                    stopButton
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .foregroundStyle(.white)
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .task { startRecording() }
        .onDisappear { cleanup() }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Button {
                cleanup()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(12)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            Spacer()
            Text("Quick Dictate")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            // Spacer for symmetry with the close button.
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var recordingStack: some View {
        VStack(spacing: 24) {
            Waveform(level: engine.audioLevel)
                .frame(height: 80)

            Text(engine.liveTranscript.isEmpty ? "Listening…" : engine.liveTranscript)
                .font(.system(.title3, design: .default))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 12)
                .animation(.easeInOut(duration: 0.15), value: engine.liveTranscript)
        }
    }

    private var polishingStack: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.5)
            Text("Polishing…")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var confirmationStack: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(Color.green)

            Text("Copied to clipboard")
                .font(.headline)

            Text(polishedPreview)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 8)

            pasteTargetRow
        }
    }

    private var pasteTargetRow: some View {
        HStack(spacing: 14) {
            ForEach(pasteTargets.bannerTargets()) { target in
                Button {
                    Task {
                        await pasteTargets.launch(target)
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: target.symbolName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                            )
                        Text(target.name)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var stopButton: some View {
        Button {
            Task { await finishRecording() }
        } label: {
            Text("Done")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor)
                )
        }
    }

    // MARK: - Lifecycle

    private func startRecording() {
        // Clear any previous completion hooks first.
        engine.silenceThreshold = settings.silenceAutoStopSeconds
        engine.onSilenceDetected = {
            Task { await finishRecording() }
        }
        engine.onPolishComplete = { polished in
            handlePolishComplete(polished)
        }

        Task {
            await engine.start(withSilenceAutoStop: true)
        }
    }

    private func finishRecording() async {
        guard engine.isRecording else { return }
        phase = .polishing
        await engine.stop()
        // onPolishComplete fires from within stop()'s polish() call.
    }

    private func handlePolishComplete(_ polished: String) {
        // Copy to clipboard.
        if settings.autoCopyAfterQuickDictate {
            UIPasteboard.general.string = polished
        }

        // Record to history.
        let entry = DictationHistoryEntry(
            rawTranscript: engine.liveTranscript,
            polishedTranscript: polished,
            tonePreset: engine.tonePreset.rawValue,
            activePacks: Array(vocabManager.activePackNames)
        )
        history.add(entry)

        // Preview + phase transition.
        polishedPreview = entry.previewSnippet
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .confirmed
        }

        // Auto-dismiss after a short confirmation window (2s). The
        // user can still tap paste targets during this window since
        // tapping them launches another app before this fires.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            dismiss()
        }
    }

    private func cleanup() {
        engine.onSilenceDetected = nil
        engine.onPolishComplete = nil
    }
}

// MARK: - Waveform

/// Tiny reactive waveform — a ring of bars scaled by the current
/// engine audio level. Good enough for the 5-second Quick Dictate
/// interaction; swap for a real FFT visualizer later.
private struct Waveform: View {
    let level: Float

    private let barCount = 27

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 4, height: barHeight(at: i))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }

    /// Height for bar `i` derived from a sinusoid offset and the
    /// current level. Creates an always-live, mic-reactive look.
    private func barHeight(at i: Int) -> CGFloat {
        let centerDistance = abs(Double(i) - Double(barCount) / 2)
        let falloff = 1.0 - (centerDistance / Double(barCount))
        let base: Double = 6
        let boost: Double = max(6, Double(level) * 90)
        return CGFloat(base + boost * falloff)
    }
}

#Preview {
    QuickDictateView()
        .environmentObject(DictationEngine())
        .environmentObject(VocabPackManager())
        .environmentObject(DictationHistoryStore())
        .environmentObject(PasteTargetsManager())
        .environmentObject(AppSettings())
}
