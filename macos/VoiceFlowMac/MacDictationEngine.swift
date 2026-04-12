//
//  MacDictationEngine.swift
//  VoiceFlowMac
//
//  macOS adaptation of the iOS DictationEngine. Uses
//  SFSpeechRecognizer + AVAudioEngine for mic capture.
//
//  Key differences from iOS:
//  - No AVAudioSession (macOS does not have it).
//  - AVAudioEngine.inputNode works directly without session config.
//  - After dictation stops, result is cleaned via ClaudeCleanup
//    then copied to the system clipboard.
//
//  Same 55-second session rotation and silence detection as iOS.
//

import Foundation
import Speech
import AVFoundation
import Combine
import AppKit

@MainActor
final class MacDictationEngine: ObservableObject {

    // MARK: - Published state

    @Published var liveTranscript: String = ""
    @Published var polishedTranscript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isPolishing: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var audioLevel: Float = 0.0

    /// Called when the engine auto-detects silence.
    var onSilenceDetected: (() -> Void)?

    /// How long to wait after the last non-silent buffer before
    /// firing onSilenceDetected.
    var silenceThreshold: TimeInterval = 2.0

    /// Called once after polish() finishes, with the final text.
    var onPolishComplete: ((String) -> Void)?

    // MARK: - Configuration

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

    /// Wall-clock of the most recent buffer that was "loud enough".
    private var lastNonSilentAt: Date = Date()
    private let silenceRMSThreshold: Float = 0.02
    private var silencePollTimer: Timer?
    private var silenceDetectionEnabled: Bool = false

    /// Universal dev/git/HTTP vocabulary pushed into
    /// SFSpeechRecognizer contextualStrings for the Code tone.
    fileprivate static let codeToneContextualStrings: [String] = [
        "pull request", "merge request", "merge conflict", "rebase",
        "cherry-pick", "fast-forward", "upstream", "origin", "branch",
        "commit", "diff", "stash", "squash", "force push",
        "GET request", "POST request", "PUT request", "PATCH request",
        "DELETE request", "HEAD request", "OPTIONS request",
        "API", "endpoint", "payload", "JSON", "GraphQL", "gRPC",
        "webhook", "middleware", "rate limit", "auth token", "JWT",
        "OAuth", "bearer token", "CORS",
        "TypeScript", "JavaScript", "Python", "Swift", "Kotlin", "Rust",
        "Golang", "React", "SwiftUI", "UIKit", "Node.js", "Django",
        "FastAPI", "Kubernetes", "Docker", "Terraform",
        "sync", "async", "await", "promise", "callback", "closure",
        "mutex", "semaphore", "lambda",
        "p50", "p95", "p99", "SLO", "SLA", "k8s", "OOM", "LRU cache",
    ]

    private var terminateObserver: Any?

    // MARK: - Init / Deinit

    init() {
        // Release mic when the app quits.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.cancel()
        }
    }

    deinit {
        if let obs = terminateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        if !speechOK {
            errorMessage = "Speech recognition permission denied."
        }
        return speechOK
    }

    // MARK: - Public API

    func start(withSilenceAutoStop: Bool = true) async {
        self.silenceDetectionEnabled = withSilenceAutoStop
        guard !isRecording else { return }

        let granted = await requestPermissions()
        guard granted else {
            print("[VF] Speech permission denied")
            return
        }
        print("[VF] Speech permission OK")

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            print("[VF] Speech recognizer unavailable")
            return
        }
        print("[VF] Recognizer available, starting...")

        stitchedSegments.removeAll()
        liveTranscript = ""
        polishedTranscript = ""
        errorMessage = nil

        do {
            try startNewRecognitionSession()
            isRecording = true
            lastNonSilentAt = Date()
            print("[VF] Recording started")
            scheduleRotationTimer()
            if silenceDetectionEnabled {
                scheduleSilencePollTimer()
            }
        } catch {
            errorMessage = "Could not start dictation: \(error.localizedDescription)"
            print("[VF] Start FAILED: \(error)")
            teardownAudio()
        }
    }

    func stop() async {
        guard isRecording else { return }

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

        await polish()
    }

    /// Toggle dictation on/off. Used by the global hotkey.
    func toggle() async {
        if isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func clearBuffers() {
        liveTranscript = ""
        polishedTranscript = ""
        stitchedSegments.removeAll()
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

        var contextual: [String] = []
        if tonePreset == .code {
            contextual.append(contentsOf: Self.codeToneContextualStrings)
        }
        if !contextual.isEmpty {
            request.contextualStrings = contextual
        }

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        print("[VF] Audio format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "MacDictationEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No audio input device. Check System Settings > Sound > Input and Privacy > Microphone."]
            )
        }

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
        // Always remove tap and stop, unconditionally.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
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

        let request = ClaudeCleanup.Request(
            rawTranscript: raw,
            tone: tonePreset,
            packPromptHints: nil,
            packTermsBlock: nil,
            model: .haiku
        )

        do {
            let cleaned = try await ClaudeCleanup.shared.clean(request)
            polishedTranscript = cleaned

            // Copy to clipboard.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(cleaned, forType: .string)

            onPolishComplete?(cleaned)
        } catch {
            errorMessage = "Polish failed: \(error.localizedDescription)"
        }
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
