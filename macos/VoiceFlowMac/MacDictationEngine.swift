//
//  MacDictationEngine.swift
//  VoiceFlowMac
//
//  macOS-specific dictation engine using SFSpeechRecognizer + AVAudioEngine.
//
//  Key differences from the iOS DictationEngine:
//   - NO AVAudioSession (iOS-only). Audio input is configured directly
//     via AVAudioEngine.inputNode on macOS.
//   - Auto-clipboard: after cleanup, polished text goes to NSPasteboard
//     automatically.
//   - Simplified for menu-bar utility: no Pro Polish, no vocab packs
//     in v1, no splice context.
//
//  Handles Apple's ~1-minute per-request limit by rotating recognition
//  sessions every ~55 seconds and stitching finalized segments.
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

    /// Clean, AI-polished transcript. Populated after cleanup finishes.
    @Published var polishedTranscript: String = ""

    /// True while the microphone is actively capturing audio.
    @Published private(set) var isRecording: Bool = false

    /// True while the Claude cleanup request is in-flight.
    @Published private(set) var isPolishing: Bool = false

    /// Last user-visible error, if any.
    @Published var errorMessage: String?

    /// 0.0-1.0 normalized mic level, drives the waveform display.
    @Published private(set) var audioLevel: Float = 0.0

    /// Active tone preset.
    @Published var tonePreset: TonePreset = .loadPersisted() {
        didSet { tonePreset.persist() }
    }

    /// When true, polished text is auto-copied to clipboard.
    @Published var autoClipboard: Bool = true

    // MARK: - Silence detection

    /// How long to wait after the last non-silent buffer before
    /// auto-stopping. Set to 0 to disable.
    var silenceThreshold: TimeInterval = 3.0

    /// Called when the engine auto-detects silence and stops.
    var onSilenceDetected: (() -> Void)?

    // MARK: - Speech / audio internals

    private let speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Accumulated finalized transcript from previous rotation segments.
    private var finalizedText: String = ""

    /// Timer for rotating the recognition session before Apple's 1-minute
    /// limit hits.
    private var rotationTimer: Timer?

    /// Timestamp of the last buffer that had non-trivial audio level.
    private var lastNonSilentTime: Date = Date()

    /// Timer that checks for silence.
    private var silenceTimer: Timer?

    // MARK: - Init

    init() {
        requestPermissions()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                switch status {
                case .authorized:
                    break
                case .denied, .restricted:
                    self?.errorMessage = "Speech recognition permission denied. Enable in System Settings > Privacy & Security > Speech Recognition."
                case .notDetermined:
                    self?.errorMessage = "Speech recognition permission not yet granted."
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRecording else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognizer is not available on this system."
            return
        }

        errorMessage = nil
        liveTranscript = ""
        polishedTranscript = ""
        finalizedText = ""
        lastNonSilentTime = Date()
        typedCharacterCount = 0
        previousLiveTranscript = ""

        do {
            TonePlayer.shared.playStart()
            try startAudioEngineAndRecognition()
            isRecording = true
            startSilenceTimer()
        } catch {
            errorMessage = "Failed to start audio: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        TonePlayer.shared.playStop()
        stopSilenceTimer()
        stopAudioEngine()

        // Trigger cleanup
        let rawTranscript = buildFinalTranscript()
        if !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await polish(rawTranscript: rawTranscript)
            }
        }
    }

    /// Toggle start/stop — used by the global hotkey.
    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Audio engine (macOS — no AVAudioSession)

    private func startAudioEngineAndRecognition() throws {
        // Cancel any prior task
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        // On macOS there is no AVAudioSession. We configure the input
        // node directly from AVAudioEngine.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate that we actually have a usable audio format
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw NSError(
                domain: "MacDictationEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No audio input device available. Check System Settings > Sound > Input."]
            )
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            self?.updateAudioLevel(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionRequest = request
        startRecognitionTask(request: request)

        // Rotate before Apple's 1-minute limit
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rotateRecognitionSession()
            }
        }
    }

    private func startRecognitionTask(request: SFSpeechAudioBufferRecognitionRequest) {
        guard let speechRecognizer else { return }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let partial = result.bestTranscription.formattedString
                    self.liveTranscript = self.finalizedText.isEmpty
                        ? partial
                        : self.finalizedText + " " + partial
                }

                if let error {
                    // Ignore cancellation errors from rotation
                    let nsError = error as NSError
                    if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 216 {
                        // Only show non-trivial errors
                        if self.isRecording {
                            self.errorMessage = "Recognition error: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func rotateRecognitionSession() {
        guard isRecording else { return }

        // Capture whatever we have so far
        let currentLive = liveTranscript
        finalizedText = currentLive

        // Tear down old recognition (keep audio engine running)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        // Start a new recognition request on the existing audio tap
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = false

        // Re-install tap is not needed — the existing tap will feed
        // into the new request once we set recognitionRequest. But
        // since the tap closure captures the old request, we need to
        // reinstall it.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            newRequest.append(buffer)
            self?.updateAudioLevel(buffer: buffer)
        }

        recognitionRequest = newRequest
        startRecognitionTask(request: newRequest)
    }

    private func stopAudioEngine() {
        rotationTimer?.invalidate()
        rotationTimer = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func buildFinalTranscript() -> String {
        return liveTranscript
    }

    // MARK: - Audio level metering

    private nonisolated func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }

        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

        // Convert to 0-1 range with some scaling for typical speech levels
        let level = max(0, min(1, rms * 5))

        Task { @MainActor [weak self] in
            self?.audioLevel = level
            if level > 0.01 {
                self?.lastNonSilentTime = Date()
            }
        }
    }

    // MARK: - Silence detection

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, self.silenceThreshold > 0 else { return }

                let elapsed = Date().timeIntervalSince(self.lastNonSilentTime)
                if elapsed >= self.silenceThreshold,
                   !self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.stop()
                    self.onSilenceDetected?()
                }
            }
        }
    }

    private func stopSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - Polish (Claude cleanup)

    private func polish(rawTranscript: String) async {
        isPolishing = true
        defer { isPolishing = false }

        let request = ClaudeCleanup.Request(
            rawTranscript: rawTranscript,
            tone: tonePreset,
            packPromptHints: nil,
            packTermsBlock: nil,
            model: .haiku
        )

        do {
            let cleaned = try await ClaudeCleanup.shared.clean(request)
            polishedTranscript = cleaned
            copyAndPaste(cleaned)
        } catch {
            errorMessage = "Cleanup failed: \(error.localizedDescription)"
            polishedTranscript = rawTranscript
            copyAndPaste(rawTranscript)
        }
    }

    // MARK: - Paste into active app

    /// Copy text to clipboard, then paste into the frontmost app
    /// via AppleScript. No Accessibility permissions needed.
    private func copyAndPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V via AppleScript — works without
        // Accessibility permissions.
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
        }
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
