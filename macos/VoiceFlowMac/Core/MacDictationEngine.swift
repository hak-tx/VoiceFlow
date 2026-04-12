//
//  MacDictationEngine.swift
//  VoiceFlowMac
//
//  Live streaming dictation using SFSpeechRecognizer on macOS.
//  Handles Apple's 1-minute per-request limit by rotating sessions
//  every ~55 seconds and stitching finalized segments.
//
//  On stop, builds a cleanup request and ships it through
//  ClaudeCleanup. Supports both fresh dictation and replace-selection
//  mode (where the user selects text, dictates a replacement, and
//  the LLM cleans the replacement in context).
//

import Foundation
import Speech
import AVFoundation
import Combine
import AppKit

@MainActor
final class MacDictationEngine: ObservableObject {

    // MARK: - Published state

    /// Live, incrementally updating transcript shown while recording.
    @Published var liveTranscript: String = ""

    /// Clean, AI-polished transcript. Populated after polish().
    @Published var polishedTranscript: String = ""

    /// Snapshot of the most recent polished transcript for undo/redo.
    @Published private(set) var cachedPolishedTranscript: String = ""

    /// True while the microphone is actively capturing.
    @Published private(set) var isRecording: Bool = false

    /// True while replacing a selected chunk of existing text.
    @Published private(set) var isReplacingSelection: Bool = false

    /// True while the polish request is in-flight.
    @Published private(set) var isPolishing: Bool = false

    /// Last user-visible error.
    @Published var errorMessage: String?

    /// 0.0-1.0 normalized mic level for waveform display.
    @Published private(set) var audioLevel: Float = 0.0

    /// Called when polish completes with the final text.
    var onPolishComplete: ((String) -> Void)?

    // MARK: - Collaborators (set by wiring)

    weak var vocabManager: MacVocabPackManager?
    var settings: MacAppSettings?

    /// Active tone preset. Persisted via TonePreset.loadPersisted().
    @Published var tonePreset: TonePreset = .loadPersisted() {
        didSet { tonePreset.persist() }
    }

    // MARK: - Speech / audio plumbing

    private let speechRecognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var stitchedSegments: [String] = []
    private var rotationTimer: Timer?
    private let rotationInterval: TimeInterval = 55.0

    /// Splice context for replace-selection mode.
    private var replaceBase: String?
    private var replaceRange: NSRange?
    private var spliceBefore: String = ""
    private var spliceAfter: String = ""

    /// Code tone contextual strings for SFSpeechRecognizer bias.
    private static let codeToneContextualStrings: [String] = [
        "pull request", "merge request", "merge conflict", "rebase",
        "cherry-pick", "fast-forward", "upstream", "origin", "branch",
        "commit", "diff", "stash", "squash", "force push",
        "GET request", "POST request", "PUT request", "PATCH request",
        "DELETE request", "HEAD request", "OPTIONS request",
        "API", "endpoint", "payload", "JSON", "GraphQL", "gRPC",
        "webhook", "middleware", "rate limit", "auth token", "JWT",
        "OAuth", "bearer token", "CORS",
        "TypeScript", "JavaScript", "Python", "Swift", "Kotlin", "Rust",
        "Golang", "React", "SwiftUI", "Node.js", "Django",
        "FastAPI", "Kubernetes", "Docker", "Terraform",
        "sync", "async", "await", "promise", "callback", "closure",
        "mutex", "semaphore", "lambda",
        "p50", "p95", "p99", "SLO", "SLA", "k8s", "OOM", "LRU cache",
    ]

    /// Silence detection.
    private var lastNonSilentAt: Date = Date()
    private let silenceRMSThreshold: Float = 0.02
    private var silencePollTimer: Timer?

    /// Seconds of silence before auto-stopping.
    var silenceThreshold: TimeInterval = 2.0

    /// Called when silence is detected during active recording.
    var onSilenceDetected: (() -> Void)?

    // MARK: - Public API

    /// Ask for microphone + speech recognition permissions on macOS.
    func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }

        // macOS microphone permission
        let micOK: Bool
        if #available(macOS 14.0, *) {
            micOK = await AVAudioApplication.requestRecordPermission()
        } else {
            micOK = true // Pre-Sonoma: permission is granted at first use
        }

        if !speechOK || !micOK {
            errorMessage = "Microphone or speech recognition permission denied. Check System Settings → Privacy & Security."
        }
        return speechOK && micOK
    }

    /// Begin a new dictation session.
    func start() async {
        if !isReplacingSelection {
            self.replaceBase = nil
            self.replaceRange = nil
        }
        await startInternal()
    }

    /// Start dictating a replacement for selected text. The next
    /// polish() will splice the cleaned new speech into `base` at
    /// `range`.
    func startReplacingSelection(in base: String, range: NSRange, before: String, after: String) async {
        let ns = base as NSString
        let safeRange = NSRange(
            location: max(0, min(range.location, ns.length)),
            length: max(0, min(range.length, ns.length - min(range.location, ns.length)))
        )
        self.replaceBase = base
        self.replaceRange = safeRange
        self.spliceBefore = before
        self.spliceAfter = after
        self.isReplacingSelection = true
        self.stitchedSegments.removeAll()
        self.liveTranscript = ""
        await startInternal()
    }

    private func startInternal() async {
        guard !isRecording else { return }

        let granted = await requestPermissions()
        guard granted else { return }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable on this Mac."
            return
        }

        stitchedSegments.removeAll()
        liveTranscript = ""
        if !isReplacingSelection {
            polishedTranscript = ""
            cachedPolishedTranscript = ""
        }
        errorMessage = nil

        do {
            try startNewRecognitionSession()
            isRecording = true
            lastNonSilentAt = Date()
            scheduleRotationTimer()
            scheduleSilencePollTimer()
        } catch {
            errorMessage = "Could not start dictation: \(error.localizedDescription)"
            teardownAudio()
        }
    }

    /// Stop dictation and kick off AI polishing.
    func stop() async {
        guard isRecording else { return }

        isRecording = false
        rotationTimer?.invalidate()
        rotationTimer = nil
        silencePollTimer?.invalidate()
        silencePollTimer = nil

        finalizeCurrentSegmentIntoStitched()
        teardownAudio()
        audioLevel = 0

        liveTranscript = stitchedSegments
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        await polish()
    }

    /// Revert to the raw transcript (undo polish).
    func revertToRaw() {
        polishedTranscript = ""
    }

    /// Restore the cached polished transcript (redo).
    func redoPolish() {
        guard !cachedPolishedTranscript.isEmpty else { return }
        polishedTranscript = cachedPolishedTranscript
    }

    /// Wipe everything.
    func clearBuffers() {
        liveTranscript = ""
        polishedTranscript = ""
        cachedPolishedTranscript = ""
        stitchedSegments.removeAll()
        replaceBase = nil
        replaceRange = nil
        isReplacingSelection = false
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

    private func startNewRecognitionSession(
        keepingAudioEngineRunning: Bool = false
    ) throws {
        guard let recognizer = speechRecognizer else {
            throw NSError(
                domain: "MacDictationEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No recognizer"]
            )
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        // Bias toward domain vocabulary.
        var contextual: [String] = []
        if let packTerms = vocabManager?.combinedContextualStrings() {
            contextual.append(contentsOf: packTerms)
        }
        if tonePreset == .code {
            contextual.append(contentsOf: Self.codeToneContextualStrings)
        }
        if !contextual.isEmpty {
            request.contextualStrings = contextual
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
                    self.liveTranscript = combined
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

    private func teardownAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    // MARK: - Cleanup

    func polish() async {
        let raw = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        isPolishing = true
        defer { isPolishing = false }

        let model: ClaudeCleanup.Model = .haiku

        var spliceCtx: ClaudeCleanup.SpliceContext?
        if replaceBase != nil, replaceRange != nil {
            spliceCtx = ClaudeCleanup.SpliceContext(
                before: spliceBefore,
                after: spliceAfter
            )
        }

        let request = ClaudeCleanup.Request(
            rawTranscript: raw,
            tone: tonePreset,
            packPromptHints: vocabManager?.combinedPromptHints(),
            packTermsBlock: vocabManager?.combinedTermsBlock(),
            model: model,
            spliceContext: spliceCtx
        )

        do {
            let cleaned = try await ClaudeCleanup.shared.clean(request)

            if let base = replaceBase, let range = replaceRange {
                let mutable = NSMutableString(string: base)
                mutable.replaceCharacters(in: range, with: cleaned)
                let spliced = mutable as String
                polishedTranscript = spliced
                cachedPolishedTranscript = spliced
                liveTranscript = spliced
                replaceBase = nil
                replaceRange = nil
                isReplacingSelection = false
                onPolishComplete?(spliced)
            } else {
                polishedTranscript = cleaned
                cachedPolishedTranscript = cleaned
                onPolishComplete?(cleaned)
            }
        } catch {
            errorMessage = "Polish failed: \(error.localizedDescription)"
            if let base = replaceBase {
                polishedTranscript = base
                liveTranscript = base
                cachedPolishedTranscript = base
            }
            replaceBase = nil
            replaceRange = nil
            isReplacingSelection = false
        }
    }

    /// The visible transcript — polished if available, else raw.
    var visibleTranscript: String {
        if !polishedTranscript.isEmpty { return polishedTranscript }
        return liveTranscript
    }

    // MARK: - Helpers

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
        return min(1.0, rms * 4.0)
    }
}
