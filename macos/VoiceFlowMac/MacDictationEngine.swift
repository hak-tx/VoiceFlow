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

    // MARK: - Live typing state

    /// How many characters we've typed into the active app so far.
    /// Used to delete-and-retype when the recognizer revises words,
    /// and to select-all-and-replace after cleanup.
    private var typedCharCount: Int = 0

    /// The last transcript we typed into the active app. Compared
    /// against new partials to compute the diff.
    private var lastTypedText: String = ""

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
                print("[VF] Speech auth status: \(status.rawValue) (0=notDetermined, 1=denied, 2=restricted, 3=authorized)")
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
        print("[VF] start() called, isRecording=\(isRecording)")
        guard !isRecording else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognizer is not available on this system."
            print("[VF] FAIL: recognizer nil or unavailable")
            return
        }
        print("[VF] Recognizer OK, starting audio...")

        errorMessage = nil
        liveTranscript = ""
        polishedTranscript = ""
        finalizedText = ""
        lastNonSilentTime = Date()
        typedCharCount = 0
        lastTypedText = ""
        NSSound(named: "Tink")?.play() // start tone

        do {
            try startAudioEngineAndRecognition()
            isRecording = true
            print("[VF] Recording STARTED - speak now")
            startSilenceTimer()
        } catch {
            errorMessage = "Failed to start audio: \(error.localizedDescription)"
            print("[VF] FAIL: \(error)")
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        NSSound(named: "Pop")?.play() // stop tone
        stopSilenceTimer()
        stopAudioEngine()

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)

            // Compute RMS on audio thread, update UI on main.
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            let samples = channelData.pointee
            var sum: Float = 0
            for i in 0..<frameLength { let v = samples[i]; sum += v * v }
            let rms = sqrt(sum / Float(frameLength))
            let level = max(0.0, min(1.0, rms * 5.0))

            Task { @MainActor [weak self] in
                self?.audioLevel = level
                if level > 0.01 {
                    self?.lastNonSilentTime = Date()
                }
            }
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
                    let combined = self.finalizedText.isEmpty
                        ? partial
                        : self.finalizedText + " " + partial
                    self.liveTranscript = combined

                    // Type live text at the cursor in the active app.
                    self.typeIncrementalUpdate(combined)
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            newRequest.append(buffer)
            let channelData = buffer.floatChannelData
            let frameLength = Int(buffer.frameLength)
            guard let samples = channelData?.pointee, frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength { let v = samples[i]; sum += v * v }
            let level = max(0.0, min(1.0, sqrt(sum / Float(frameLength)) * 5.0))
            Task { @MainActor [weak self] in
                self?.audioLevel = level
                if level > 0.01 { self?.lastNonSilentTime = Date() }
            }
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

            // Delete the raw text we typed, replace with cleaned.
            replaceTypedText(with: cleaned)

            // Also copy to clipboard for easy paste elsewhere.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cleaned, forType: .string)
        } catch {
            // Cleanup failed — the raw text is already at the cursor
            // from live typing, so just leave it. Log the error.
            print("[VF] Cleanup failed: \(error.localizedDescription)")
            polishedTranscript = rawTranscript
        }
    }

    // MARK: - Live typing at cursor via CGEvent

    /// Insert text at the cursor in the frontmost app.
    /// Uses CGEvent keyboard simulation — requires Accessibility
    /// permission on a stable (non-Xcode-debug) binary.
    /// Type a string at the cursor via CGEvent keyboard simulation.
    private func cgType(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for char in text {
            let utf16 = Array(String(char).utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Paste text at cursor — copies to clipboard + types via CGEvent.
    private func pasteTextAtCursor(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        cgType(text)
    }

    /// Type incremental updates into the active app LIVE as the
    /// user speaks. Compares new transcript against what's already
    /// typed and only sends the diff.
    private func typeIncrementalUpdate(_ current: String) {
        if current.hasPrefix(lastTypedText) {
            let newPart = String(current.dropFirst(lastTypedText.count))
            if !newPart.isEmpty {
                cgType(newPart)
                typedCharCount += newPart.count
            }
        } else {
            // Recognizer revised earlier words — delete and retype.
            cgDeleteBackward(typedCharCount)
            cgType(current)
            typedCharCount = current.count
        }
        lastTypedText = current
    }

    /// After cleanup, delete the raw text and type the cleaned text.
    private func replaceTypedText(with cleaned: String) {
        cgDeleteBackward(typedCharCount)
        cgType(cleaned)
        typedCharCount = 0
        lastTypedText = ""
    }

    /// Simulate pressing Delete/Backspace N times.
    private func cgDeleteBackward(_ count: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true) {
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
