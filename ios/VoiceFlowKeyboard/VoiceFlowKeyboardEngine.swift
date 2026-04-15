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

    /// Called to read all text from the current text field.
    /// Returns the full document text for AI cleanup.
    var onReadAllText: (() -> String)?

    /// Called to replace all text in the current text field.
    var onReplaceAllText: ((String) -> Void)?

    /// Called when user taps the mic button — opens main VoiceFlow
    /// app for dictation (keyboard extensions can't reliably use
    /// AVAudioEngine due to iOS sandbox restrictions).
    var onOpenMainAppForDictation: (() -> Void)?

    /// True while AI autocorrect is processing.
    @Published private(set) var isCleaning: Bool = false

    /// True when there are cleanups that can be undone.
    @Published private(set) var canUndo: Bool = false

    /// Stack of (rawText, cleanedText) pairs for multi-level undo.
    /// Most recent cleanup is last.
    private var undoStack: [(raw: String, cleaned: String)] = []

    /// Accumulated typed text for sentence detection.
    private var typedBuffer: String = ""

    // MARK: - AI Autocorrect

    /// Called after the user types a sentence-ending character
    /// (period, question mark, exclamation, return). Reads the
    /// current text, sends to Claude for cleanup, replaces in-place.
    func cleanupTypedText() {
        guard let readAll = onReadAllText,
              let replaceAll = onReplaceAllText else { return }

        let rawText = readAll()
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            isCleaning = true
            defer { isCleaning = false }

            let request = ClaudeCleanup.Request(
                rawTranscript: rawText,
                tone: tonePreset,
                packPromptHints: nil,
                packTermsBlock: nil,
                model: .haiku
            )

            do {
                let cleaned = try await ClaudeCleanup.shared.clean(request)
                if cleaned != rawText {
                    // Push to undo stack before replacing.
                    undoStack.append((raw: rawText, cleaned: cleaned))
                    // Keep max 10 undo levels.
                    if undoStack.count > 10 { undoStack.removeFirst() }
                    canUndo = true
                    replaceAll(cleaned)
                }
            } catch {
                // Silent fail — don't disrupt typing
            }
        }
    }

    /// Undo the most recent AI cleanup — restores the raw text.
    /// Can be called multiple times to undo multiple cleanups.
    func undoLastCleanup() {
        guard let last = undoStack.popLast(),
              let replaceAll = onReplaceAllText,
              let readAll = onReadAllText else { return }

        let currentText = readAll()
        // Replace the cleaned text with the raw version.
        // The current text should contain the cleaned version.
        let restored = currentText.replacingOccurrences(
            of: last.cleaned,
            with: last.raw
        )
        if restored != currentText {
            replaceAll(restored)
        } else {
            // Fallback: just replace everything with raw.
            replaceAll(last.raw)
        }
        canUndo = !undoStack.isEmpty
    }

    /// Track keystrokes for auto-cleanup trigger.
    func keyTyped(_ key: String) {
        onInsertText?(key)
        typedBuffer += key

        // Trigger cleanup after sentence-ending punctuation.
        if key == "." || key == "?" || key == "!" || key == "\n" {
            // Small delay so the character is inserted first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.cleanupTypedText()
            }
            typedBuffer = ""
        }
    }

    // MARK: - Speech plumbing

    private let speechRecognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// AVAudioRecorder works in keyboard extensions where AVAudioEngine
    /// fails (CoreAudio error 2003329396). Records to a file, then
    /// transcribes with SFSpeechURLRecognitionRequest after stop.
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private let maxRecordingDuration: TimeInterval = 60.0
    private let silenceThreshold: TimeInterval = 2.0
    private var lastNonSilentAt: Date = Date()
    private let silenceMeterThreshold: Float = -40.0  // dB

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

        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else {
            errorMessage = "Speech recognition not authorized."
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            return
        }

        liveTranscript = ""
        errorMessage = nil
        lastNonSilentAt = Date()
        recordingStartedAt = Date()

        // Create a temp file to record to.
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(
            "vf-\(UUID().uuidString).m4a"
        )
        recordingURL = url

        // Configure session for recording.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session error: \(error.localizedDescription)"
            return
        }

        // AVAudioRecorder settings — M4A/AAC, 16kHz mono is plenty
        // for speech recognition and small enough for fast upload.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "Could not start recorder."
                return
            }
            audioRecorder = recorder
            isRecording = true
            scheduleMeteringTimer()
        } catch {
            errorMessage = "Recorder failed: \(error.localizedDescription)"
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil

        audioRecorder?.stop()
        let url = recordingURL
        audioRecorder = nil
        recordingURL = nil

        try? AVAudioSession.sharedInstance().setActive(false)
        audioLevel = 0

        // Transcribe the recorded file via SFSpeechURLRecognitionRequest.
        guard let url, let recognizer = speechRecognizer else { return }

        let raw = await transcribeFile(at: url, with: recognizer)
        // Clean up the temp file.
        try? FileManager.default.removeItem(at: url)

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        liveTranscript = trimmed
        await polishAndInsert(raw: trimmed)
    }

    /// Transcribe an audio file using SFSpeechURLRecognitionRequest.
    private func transcribeFile(
        at url: URL,
        with recognizer: SFSpeechRecognizer
    ) async -> String {
        return await withCheckedContinuation { cont in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if #available(iOS 16.0, *) {
                request.addsPunctuation = true
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    print("[VFKB] transcribe error: \(error.localizedDescription)")
                    cont.resume(returning: "")
                    return
                }
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    /// Poll the recorder's audio levels for live waveform + silence
    /// auto-stop detection.
    private func scheduleMeteringTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.audioRecorder else { return }
                recorder.updateMeters()
                let avgPower = recorder.averagePower(forChannel: 0)
                // Convert dB to 0-1 normalized level.
                let normalized = max(0, (avgPower + 60) / 60)
                self.audioLevel = normalized

                if avgPower > self.silenceMeterThreshold {
                    self.lastNonSilentAt = Date()
                }

                // Auto-stop on max duration.
                if let started = self.recordingStartedAt,
                   Date().timeIntervalSince(started) >= self.maxRecordingDuration {
                    await self.stop()
                    return
                }

                // Auto-stop on silence (only after some speech detected).
                let elapsed = Date().timeIntervalSince(self.lastNonSilentAt)
                if elapsed >= self.silenceThreshold {
                    await self.stop()
                }
            }
        }
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
