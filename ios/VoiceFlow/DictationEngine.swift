//
//  DictationEngine.swift
//  VoiceFlow
//
//  Live streaming dictation using SFSpeechRecognizer with partial
//  results. Handles the 1-minute per-request limit imposed by
//  Apple's speech framework by rotating SFSpeechAudioBufferRecognitionRequest
//  sessions every ~55 seconds and stitching finalized segments into a
//  single continuous transcript.
//
//  On stop, calls `polish()` which ships the raw transcript to the
//  Anthropic API (claude-haiku-4-5-20251001) for filler removal,
//  punctuation repair, and voice-preserving cleanup.
//

import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class DictationEngine: ObservableObject {

    // MARK: - Published state

    /// Live, incrementally updating transcript shown while recording.
    /// Combines already-finalized stitched text with the in-flight
    /// partial result from the current session.
    @Published private(set) var liveTranscript: String = ""

    /// Clean, AI-polished transcript. Populated after `polish()` finishes.
    @Published private(set) var polishedTranscript: String = ""

    /// True while the microphone is actively capturing audio.
    @Published private(set) var isRecording: Bool = false

    /// True while the polish request is in-flight.
    @Published private(set) var isPolishing: Bool = false

    /// Last user-visible error, if any.
    @Published var errorMessage: String?

    // MARK: - Collaborators

    /// Injected so we can pull active vocab packs into the cleanup prompt.
    weak var vocabManager: VocabPackManager?

    // MARK: - Speech / audio plumbing

    private let speechRecognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Segments already finalized from previous rotated sessions. On
    /// rotation we freeze whatever has been transcribed and append it
    /// here, then start a fresh request so we never exceed the 1-minute
    /// per-request cap.
    private var stitchedSegments: [String] = []

    /// Timer that fires the rotation at the 55-second mark.
    private var rotationTimer: Timer?

    /// Rotation happens slightly under the 1-minute hard limit.
    private let rotationInterval: TimeInterval = 55.0

    // MARK: - Public API

    /// Request microphone + speech recognition permission.
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

    /// Begin a new dictation session. Clears transcripts and starts audio.
    func start() async {
        guard !isRecording else { return }

        let granted = await requestPermissions()
        guard granted else { return }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable on this device."
            return
        }

        // Reset state for a fresh session.
        stitchedSegments.removeAll()
        liveTranscript = ""
        polishedTranscript = ""
        errorMessage = nil

        do {
            try configureAudioSession()
            try startNewRecognitionSession()
            isRecording = true
            scheduleRotationTimer()
        } catch {
            errorMessage = "Could not start dictation: \(error.localizedDescription)"
            teardownAudio()
        }
    }

    /// Stop the dictation session and kick off AI polishing.
    func stop() async {
        guard isRecording else { return }

        rotationTimer?.invalidate()
        rotationTimer = nil

        // Freeze whatever is in the current request as a final segment.
        finalizeCurrentSegmentIntoStitched()
        teardownAudio()
        isRecording = false

        // liveTranscript now holds the final stitched raw text.
        liveTranscript = stitchedSegments.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        await polish()
    }

    /// Revert the visible transcript from the polished version back to
    /// the raw stitched version (for the "undo" button in the UI).
    func revertToRaw() {
        polishedTranscript = ""
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

    /// Finalize the current recognition request, append its text to the
    /// stitched buffer, and spin up a brand new request so audio keeps
    /// streaming without hitting the 1-minute limit.
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

    /// Snapshot whatever text the current recognition task has produced
    /// and push it into `stitchedSegments`, then end the request.
    private func finalizeCurrentSegmentIntoStitched() {
        // Whatever the live transcript shows minus the already-stitched
        // portion becomes this segment's finalized contribution.
        let alreadyStitched = stitchedSegments.joined(separator: " ")
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

        // Only (re)install the tap if this is a fresh start. When we
        // rotate while keeping the audio engine running, we must remove
        // the old tap first so the new request gets the stream.
        if keepingAudioEngineRunning {
            inputNode.removeTap(onBus: 0)
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let stitched = self.stitchedSegments
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let current = result.bestTranscription.formattedString
                    if stitched.isEmpty {
                        self.liveTranscript = current
                    } else {
                        self.liveTranscript = stitched + " " + current
                    }
                }
                if let error, self.isRecording {
                    // A normal end-of-audio surfaces here too; only
                    // surface as user-visible if recording is active.
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
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Anthropic cleanup

    /// Ship the raw transcript to Claude Haiku 4.5 for cleanup. Writes
    /// the result to `polishedTranscript`.
    func polish() async {
        let raw = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        isPolishing = true
        defer { isPolishing = false }

        let systemPrompt = buildSystemPrompt()

        do {
            let cleaned = try await AnthropicClient.shared.cleanup(
                rawTranscript: raw,
                systemPrompt: systemPrompt
            )
            polishedTranscript = cleaned
        } catch {
            errorMessage = "Polish failed: \(error.localizedDescription)"
        }
    }

    private func buildSystemPrompt() -> String {
        var base = """
        You are a transcript cleanup assistant. You will receive a raw \
        speech-to-text transcript from a user dictating out loud. Your job:

        1. Remove filler words (um, uh, like, you know, sort of, basically, etc.).
        2. Fix punctuation, capitalization, and sentence boundaries.
        3. Collapse obvious self-corrections (e.g. "go to the store, I mean the \
        office" -> "go to the office").
        4. Preserve the speaker's voice, tone, word choice, and meaning. Do NOT \
        paraphrase, summarize, or add new content. Do NOT answer questions in \
        the transcript - just clean them up.
        5. Output ONLY the cleaned transcript. No preamble, no explanation, no \
        markdown code fences.
        """

        if let hints = vocabManager?.combinedPromptHints(), !hints.isEmpty {
            base += "\n\nDomain context: " + hints
        }
        if let terms = vocabManager?.combinedTermsBlock(), !terms.isEmpty {
            base += "\n\nThe speaker may use these domain terms; preserve their " +
                    "exact spelling and capitalization:\n" + terms
        }
        return base
    }
}

// MARK: - Anthropic HTTP client

/// Tiny JSON client for the Anthropic Messages API. Uses the
/// `claude-haiku-4-5-20251001` model ID as requested.
struct AnthropicClient {
    static let shared = AnthropicClient()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5-20251001"
    private let anthropicVersion = "2023-06-01"

    func cleanup(rawTranscript: String, systemPrompt: String) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.addValue(Secrets.anthropicAPIKey, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": rawTranscript
                ]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "AnthropicClient",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(snippet)"]
            )
        }

        struct APIResponse: Decodable {
            struct ContentBlock: Decodable {
                let type: String
                let text: String?
            }
            let content: [ContentBlock]
        }
        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        let text = decoded.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
