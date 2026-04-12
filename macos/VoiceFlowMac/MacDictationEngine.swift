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

            // Delete the raw text we typed, replace with cleaned.
            replaceTypedText(with: cleaned)

            // Also copy to clipboard for easy paste elsewhere.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cleaned, forType: .string)
        } catch {
            errorMessage = "Cleanup failed: \(error.localizedDescription)"
            polishedTranscript = rawTranscript
        }
    }

    // MARK: - Live typing at cursor via CGEvent

    /// Type text at the cursor in the frontmost app using clipboard
    /// + Cmd+V. This is the most reliable cross-app text insertion
    /// on macOS — works everywhere CGEvent posting fails.
    private func pasteTextAtCursor(_ text: String) {
        guard !text.isEmpty else { return }

        // Save current clipboard so we can restore it.
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.compactMap { item -> (String, String)? in
            guard let type = item.types.first,
                  let data = item.string(forType: type) else { return nil }
            return (type.rawValue, data)
        } ?? []

        // Put our text on the clipboard.
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Simulate Cmd+V via AppleScript (reliable across all apps).
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            print("[VF] Paste error: \(error)")
        }

        // Restore clipboard after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !savedItems.isEmpty {
                pb.clearContents()
                for (typeRaw, data) in savedItems {
                    pb.setString(data, forType: NSPasteboard.PasteboardType(typeRaw))
                }
            }
        }
    }

    /// Type incremental updates. For live typing, we accumulate
    /// and only paste the final cleaned result (live partial results
    /// are too noisy for paste-based insertion). The user hears the
    /// start/stop tones and sees the cleanup appear after stop.
    private func typeIncrementalUpdate(_ current: String) {
        // Live text just updates the internal state.
        // Actual insertion happens after cleanup via replaceTypedText.
        lastTypedText = current
    }

    /// After cleanup, paste the cleaned text at the cursor.
    private func replaceTypedText(with cleaned: String) {
        pasteTextAtCursor(cleaned)
        typedCharCount = 0
        lastTypedText = ""
    }
}
