//
//  VoiceFlowKeyboardEngine.swift
//  VoiceFlowKeyboard
//
//  Lean mic -> speech -> Claude cleanup pipeline for the keyboard
//  extension. Not a reuse of the full DictationEngine because the
//  keyboard has a ~30MB memory ceiling and doesn't need rotation
//  bookkeeping, voice commands, usage tracking, entitlements, or
//  vocab packs.
//
//  What it does:
//    - SFSpeechRecognizer for live transcription
//    - Silence auto-stop after ~2s of no speech
//    - On stop, calls ClaudeCleanup (shared with main app) for
//      polishing
//    - Calls `onInsertText` with the polished (or raw fallback)
//      text so the KeyboardViewController can push it into the
//      host app's text field
//
//  Shared code required to be added to this target's membership:
//    - Secrets.swift
//    - ClaudeCleanup.swift
//    - TonePreset.swift
//

import Foundation
import Speech
import AVFoundation
import Combine
import UIKit

@MainActor
final class VoiceFlowKeyboardEngine: ObservableObject {

    // MARK: - Published

    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isPolishing: Bool = false
    @Published private(set) var audioLevel: Float = 0
    @Published var errorMessage: String?
    @Published var tonePreset: TonePreset = .loadPersisted()

    // MARK: - Callbacks

    /// Called with the final text to insert into the host app's
    /// text field. Polished version if cleanup succeeded, raw
    /// transcript otherwise.
    var onInsertText: ((String) -> Void)?

    /// Called when the user taps backspace to delete one character.
    var onDeleteBackward: (() -> Void)?

    /// Called when the user taps the globe key to switch keyboards.
    var onRequestKeyboardSwitch: (() -> Void)?

    // MARK: - Speech plumbing

    private let speechRecognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var lastNonSilentAt: Date = Date()
    private let silenceRMSThreshold: Float = 0.02
    private let silenceThreshold: TimeInterval = 2.0
    private var silencePollTimer: Timer?

    // MARK: - Lifecycle

    func requestKeyboardSwitch() {
        onRequestKeyboardSwitch?()
    }

    func toggle() {
        Task { @MainActor in
            if isRecording {
                await stop()
            } else {
                await start()
            }
        }
    }

    func start() async {
        guard !isRecording else { return }

        // NOTE: We skip async permission dialogs here. Keyboard
        // extensions cannot reliably present system permission alerts.
        // The main VoiceFlow app is responsible for requesting mic and
        // speech permissions during onboarding. If permissions are
        // missing the recognizer / audio engine will simply fail below
        // and we surface the error to the user.

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            return
        }

        liveTranscript = ""
        errorMessage = nil
        lastNonSilentAt = Date()

        do {
            try configureAudioSession()
            try startRecognition(with: recognizer)
            isRecording = true
            scheduleSilencePoll()
        } catch {
            errorMessage = "Could not start: \(error.localizedDescription)"
            teardown()
        }
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        silencePollTimer?.invalidate()
        silencePollTimer = nil

        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        teardown()
        audioLevel = 0

        let raw = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        await polishAndInsert(raw: raw)
    }

    // MARK: - Audio

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Keyboard extensions need .playAndRecord (not .record) to
        // coexist with the host app's audio. Use .voiceChat mode
        // instead of .measurement which isn't available in extensions.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startRecognition(with recognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            let rms = Self.rms(of: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioLevel = rms
                if rms > self.silenceRMSThreshold {
                    self.lastNonSilentAt = Date()
                }
            }
        }

        recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRecording else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                }
                if let error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func teardown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func scheduleSilencePoll() {
        silencePollTimer?.invalidate()
        silencePollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                guard !self.liveTranscript.isEmpty else { return }
                let elapsed = Date().timeIntervalSince(self.lastNonSilentAt)
                if elapsed >= self.silenceThreshold {
                    self.silencePollTimer?.invalidate()
                    self.silencePollTimer = nil
                    await self.stop()
                }
            }
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for ch in 0..<channelCount {
            let samples = channelData[ch]
            for i in 0..<frameLength {
                let v = samples[i]
                sum += v * v
            }
        }
        let mean = sum / Float(frameLength * channelCount)
        return min(1.0, sqrtf(mean) * 4.0)
    }

    // MARK: - Polish + insert

    private func polishAndInsert(raw: String) async {
        isPolishing = true
        defer { isPolishing = false }

        let request = ClaudeCleanup.Request(
            rawTranscript: raw,
            tone: tonePreset,
            packPromptHints: nil,
            packTermsBlock: nil,
            model: .haiku
        )

        do {
            let cleaned = try await ClaudeCleanup.shared.clean(request)
            onInsertText?(cleaned)
        } catch {
            // Fall back to raw transcript so the user at least gets
            // their words, and surface a toast in the UI.
            errorMessage = "Polish failed: \(error.localizedDescription)"
            onInsertText?(raw)
        }
    }
}
