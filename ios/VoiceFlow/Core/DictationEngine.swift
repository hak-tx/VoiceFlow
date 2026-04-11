//
//  DictationEngine.swift
//  VoiceFlow
//
//  Live streaming dictation using SFSpeechRecognizer with partial
//  results. Handles Apple's 1-minute per-request limit by rotating
//  SFSpeechAudioBufferRecognitionRequest sessions every ~55 seconds
//  and stitching finalized segments into a single continuous
//  transcript.
//
//  On each liveTranscript update the engine also calls into
//  VoiceCommandParser so commands like "VoiceFlow copy that" get
//  detected, removed from the transcript, and executed before
//  cleanup runs.
//
//  On stop, it builds a cleanup request (selecting Haiku vs Sonnet
//  based on the user's entitlement) and ships it through
//  ClaudeCleanup.
//

import Foundation
import Speech
import AVFoundation
import Combine
import UIKit

@MainActor
final class DictationEngine: ObservableObject {

    // MARK: - Published state

    /// Live, incrementally updating transcript shown while recording.
    /// Writable so the UI's TextEditor can also mutate it when the
    /// user edits after dictation.
    @Published var liveTranscript: String = ""

    /// Clean, AI-polished transcript. Populated after `polish()`.
    /// Writable for manual UI editing.
    @Published var polishedTranscript: String = ""

    /// Snapshot of the most recent polished transcript. Unlike
    /// `polishedTranscript` this is not cleared by revertToRaw(), so
    /// the UI's Redo button can restore it.
    @Published private(set) var cachedPolishedTranscript: String = ""

    /// True while the microphone is actively capturing audio.
    @Published private(set) var isRecording: Bool = false

    /// True while the polish request is in-flight.
    @Published private(set) var isPolishing: Bool = false

    /// Last user-visible error, if any.
    @Published var errorMessage: String?

    /// Last voice command executed; UI shows a brief confirmation.
    @Published var lastCommandConfirmation: String?

    /// 0.0–1.0 normalized mic level. Updated on every audio buffer
    /// tap. Drives the QuickDictateView waveform.
    @Published private(set) var audioLevel: Float = 0.0

    /// Called when the engine auto-detects that the user has stopped
    /// speaking (silence of `silenceThreshold` seconds). Set by
    /// QuickDictateView to trigger an automatic stop.
    var onSilenceDetected: (() -> Void)?

    /// How long to wait after the last non-silent buffer before
    /// firing `onSilenceDetected`. Exposed for configuration.
    var silenceThreshold: TimeInterval = 2.0

    /// Called exactly once after `polish()` finishes, with the final
    /// polished transcript. QuickDictateView sets this to copy the
    /// text to the clipboard and show the confirmation banner.
    var onPolishComplete: ((String) -> Void)?

    // MARK: - Collaborators (injected)

    weak var vocabManager: VocabPackManager?
    weak var entitlements: EntitlementManager?
    weak var usageTracker: UsageTracker?
    var commandParser: VoiceCommandParser?

    /// Active tone preset. Persisted via TonePreset.loadPersisted().
    @Published var tonePreset: TonePreset = .loadPersisted() {
        didSet { tonePreset.persist() }
    }

    /// Pro-only "Pro Polish" toggle (routes cleanup through Sonnet).
    @Published var proPolishEnabled: Bool = false

    // MARK: - Speech / audio plumbing

    private let speechRecognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var stitchedSegments: [String] = []
    private var rotationTimer: Timer?
    private let rotationInterval: TimeInterval = 55.0

    /// Wall-clock of the most recent buffer that was "loud enough"
    /// to count as non-silent. Used for the silence detector.
    private var lastNonSilentAt: Date = Date()
    /// Any buffer below this RMS is treated as silence.
    private let silenceRMSThreshold: Float = 0.02
    private var silencePollTimer: Timer?
    private var silenceDetectionEnabled: Bool = false

    // MARK: - Public API

    /// Ask for microphone + speech recognition permissions.
    func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        let micOK: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        if !speechOK || !micOK {
            errorMessage = "Microphone or speech recognition permission denied."
        }
        return speechOK && micOK
    }

    /// Begin a new dictation session. If `withSilenceAutoStop` is
    /// true, the engine will call `onSilenceDetected` after
    /// `silenceThreshold` seconds without speech (used by
    /// QuickDictateView).
    func start(withSilenceAutoStop: Bool = false) async {
        self.silenceDetectionEnabled = withSilenceAutoStop
        await startInternal()
    }

    private func startInternal() async {
        guard !isRecording else { return }

        let granted = await requestPermissions()
        guard granted else { return }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable on this device."
            return
        }

        stitchedSegments.removeAll()
        liveTranscript = ""
        polishedTranscript = ""
        cachedPolishedTranscript = ""
        errorMessage = nil
        lastCommandConfirmation = nil

        usageTracker?.recordSessionStart()

        do {
            try configureAudioSession()
            try startNewRecognitionSession()
            isRecording = true
            lastNonSilentAt = Date()
            scheduleRotationTimer()
            if silenceDetectionEnabled {
                scheduleSilencePollTimer()
            }
        } catch {
            errorMessage = "Could not start dictation: \(error.localizedDescription)"
            teardownAudio()
        }
    }

    /// Stop the dictation session and kick off AI polishing.
    func stop() async {
        guard isRecording else { return }

        // Flip isRecording FIRST so any late callback from the
        // recognition task (SFSpeechRecognizer often delivers one
        // final result after .finish() is called) is ignored by the
        // guard in handleTranscriptUpdate. Without this, the final
        // result re-appends the current transcript on top of an
        // already-finalized stitched segment, producing duplication
        // ("Testing testing 123 Testing testing 123").
        isRecording = false

        rotationTimer?.invalidate()
        rotationTimer = nil
        silencePollTimer?.invalidate()
        silencePollTimer = nil
        silenceDetectionEnabled = false

        finalizeCurrentSegmentIntoStitched()
        teardownAudio()
        audioLevel = 0

        liveTranscript = stitchedSegments
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        usageTracker?.recordSessionStop(finalWordCount: wordCount(liveTranscript))

        await polish()
    }

    /// Replace the visible transcript with the raw stitched version
    /// (undo the AI polish step). The polished copy stays in
    /// `cachedPolishedTranscript` so Redo can restore it.
    func revertToRaw() {
        polishedTranscript = ""
    }

    /// Reapply the last cached polished transcript. Counterpart to
    /// `revertToRaw()` — used by the Redo button in the action bar.
    func redoPolish() {
        guard !cachedPolishedTranscript.isEmpty else { return }
        polishedTranscript = cachedPolishedTranscript
    }

    /// Wipe everything — used by the "clear" voice command and the
    /// Clear action-bar button.
    func clearBuffers() {
        liveTranscript = ""
        polishedTranscript = ""
        cachedPolishedTranscript = ""
        stitchedSegments.removeAll()
    }

    /// Append a paragraph break to the live transcript. Used by the
    /// "new paragraph" voice command.
    func insertParagraphBreak() {
        liveTranscript += "\n\n"
    }

    // MARK: - Session rotation

    private func scheduleRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(
            withTimeInterval: rotationInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rotateSession()
            }
        }
    }

    private func scheduleSilencePollTimer() {
        silencePollTimer?.invalidate()
        silencePollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                // Don't fire silence until we've at least heard
                // something — otherwise hitting "Quick Dictate" and
                // pausing before speaking would auto-cancel.
                guard !self.liveTranscript.isEmpty else { return }
                let elapsed = Date().timeIntervalSince(self.lastNonSilentAt)
                if elapsed >= self.silenceThreshold {
                    self.silencePollTimer?.invalidate()
                    self.silencePollTimer = nil
                    self.onSilenceDetected?()
                }
            }
        }
    }

    private func rotateSession() {
        guard isRecording else { return }
        finalizeCurrentSegmentIntoStitched()
        do {
            try startNewRecognitionSession(keepingAudioEngineRunning: true)
            scheduleRotationTimer()
        } catch {
            errorMessage = "Session rotation failed: \(error.localizedDescription)"
        }
    }

    private func finalizeCurrentSegmentIntoStitched() {
        let alreadyStitched = stitchedSegments
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var newPortion = liveTranscript
        if !alreadyStitched.isEmpty, liveTranscript.hasPrefix(alreadyStitched) {
            newPortion = String(liveTranscript.dropFirst(alreadyStitched.count))
        }
        let trimmed = newPortion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            stitchedSegments.append(trimmed)
        }

        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
    }

    // MARK: - Audio / recognizer wiring

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .record,
            mode: .measurement,
            options: [.duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startNewRecognitionSession(
        keepingAudioEngineRunning: Bool = false
    ) throws {
        guard let recognizer = speechRecognizer else {
            throw NSError(
                domain: "DictationEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No recognizer"]
            )
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        if keepingAudioEngineRunning {
            inputNode.removeTap(onBus: 0)
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            // Also compute an RMS level on the buffer so we can drive
            // the waveform + silence detector. We jump to main actor
            // to update Published state.
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
                // Bail on any late callbacks after stop() has
                // flipped isRecording to false. SFSpeechRecognizer
                // will often deliver one final result after we've
                // already stitched + finalized, and without this
                // guard that final result gets re-appended on top
                // of the already-finalized segment, producing a
                // duplicated transcript.
                guard self.isRecording else { return }

                if let result {
                    let stitched = self.stitchedSegments
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let current = result.bestTranscription.formattedString
                    let combined: String
                    if stitched.isEmpty {
                        combined = current
                    } else {
                        combined = stitched + " " + current
                    }
                    self.handleTranscriptUpdate(combined)
                }
                if let error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }

        if !keepingAudioEngineRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    /// Called on every partial/final recognition result. Runs the
    /// voice command parser first so commands get stripped out before
    /// they ever reach the UI or the cleanup pass.
    private func handleTranscriptUpdate(_ candidate: String) {
        var next = candidate
        if let parser = commandParser {
            next = parser.scan(transcript: next, engine: self)
        }
        self.liveTranscript = next
    }

    private func teardownAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Cleanup

    /// Ship the raw transcript through ClaudeCleanup with the
    /// currently-active tone preset, vocab packs, and entitlement-
    /// appropriate model.
    func polish() async {
        let raw = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Free-tier daily word cap check.
        if let entitlements, !entitlements.hasPro {
            let words = wordCount(raw)
            if !entitlements.canConsumeFreeWords(words) {
                errorMessage = "Daily free word limit reached. Upgrade to Pro for unlimited cleanup."
                return
            }
            entitlements.consumeFreeWords(words)
        }

        isPolishing = true
        defer { isPolishing = false }

        let model: ClaudeCleanup.Model = {
            guard let entitlements, entitlements.hasPro, proPolishEnabled else {
                return .haiku
            }
            return .sonnet
        }()

        let request = ClaudeCleanup.Request(
            rawTranscript: raw,
            tone: tonePreset,
            packPromptHints: vocabManager?.combinedPromptHints(),
            packTermsBlock: vocabManager?.combinedTermsBlock(),
            model: model
        )

        do {
            let cleaned = try await ClaudeCleanup.shared.clean(request)
            polishedTranscript = cleaned
            cachedPolishedTranscript = cleaned
            usageTracker?.recordCleanup(
                wordCount: wordCount(cleaned),
                tonePreset: tonePreset,
                model: model
            )
            onPolishComplete?(cleaned)
        } catch {
            errorMessage = "Polish failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Normalized RMS [0, 1] for an incoming audio buffer.
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
        let rms = sqrtf(mean)
        // Light compression / clip.
        return min(1.0, rms * 4.0)
    }
}
