//
//  VoiceFlowKeyboardEngine.swift
//  VoiceFlowKeyboard
//
//  Chunked streaming dictation for the keyboard extension.
//  Uses alternating AVAudioRecorders (A/B) to capture continuous
//  audio in 3-second chunks. Each completed chunk is transcribed
//  via SFSpeechURLRecognitionRequest in parallel with the next
//  chunk recording, then cleaned via Claude Haiku and inserted at
//  the cursor.
//
//  This avoids AVAudioEngine (which fails in keyboard extensions
//  with CoreAudio error 2003329396) while still providing a
//  near-live streaming UX. Gap between chunks is ~50ms.
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
    @Published var tonePreset: TonePreset = .loadPersisted() {
        didSet { tonePreset.persist() }
    }

    // MARK: - Callbacks

    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onRequestKeyboardSwitch: (() -> Void)?
    var onReadAllText: (() -> String)?
    var onReplaceAllText: ((String) -> Void)?
    var onOpenMainAppForDictation: (() -> Void)?

    @Published private(set) var isCleaning: Bool = false
    @Published private(set) var canUndo: Bool = false
    private var undoStack: [(raw: String, cleaned: String)] = []
    private var typedBuffer: String = ""

    // MARK: - Chunked recording state

    private let speechRecognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Two recorders that alternate to keep audio capture continuous.
    private var recorderA: AVAudioRecorder?
    private var recorderB: AVAudioRecorder?
    private var activeRecorder: AVAudioRecorder? {
        usingRecorderA ? recorderA : recorderB
    }
    private var usingRecorderA: Bool = true

    private var chunkDuration: TimeInterval = 3.0
    private var chunkTimer: Timer?
    private var meteringTimer: Timer?
    private var sessionActive: Bool = false

    // MARK: - AI Autocorrect (typed text)

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
                    undoStack.append((raw: rawText, cleaned: cleaned))
                    if undoStack.count > 10 { undoStack.removeFirst() }
                    canUndo = true
                    replaceAll(cleaned)
                }
            } catch {
                // Silent fail
            }
        }
    }

    func undoLastCleanup() {
        guard let last = undoStack.popLast(),
              let replaceAll = onReplaceAllText,
              let readAll = onReadAllText else { return }
        let current = readAll()
        let restored = current.replacingOccurrences(of: last.cleaned, with: last.raw)
        replaceAll(restored != current ? restored : last.raw)
        canUndo = !undoStack.isEmpty
    }

    /// Word-level autocorrect using UITextChecker. Tracks the
    /// in-progress word; when the user types a space or punctuation,
    /// checks the just-completed word and replaces it with the top
    /// suggestion if it's misspelled.
    private let textChecker = UITextChecker()
    private var currentWord: String = ""

    func keyTyped(_ key: String) {
        // Word boundary: space or punctuation. Run autocorrect on
        // the just-completed word before inserting the boundary.
        let isWordBoundary = (
            key == " " || key == "." || key == "," || key == "?" ||
            key == "!" || key == ";" || key == ":" || key == "\n"
        )

        if isWordBoundary {
            autocorrectCurrentWord()
            currentWord = ""
            onInsertText?(key)
        } else {
            // Letter / digit / symbol — accumulate into current word.
            currentWord += key
            onInsertText?(key)
        }
    }

    /// Check the current word against UITextChecker and silently
    /// replace it with the top suggestion if misspelled.
    private func autocorrectCurrentWord() {
        let word = currentWord
        guard word.count >= 2 else { return }

        // Skip if the word contains digits or special characters.
        guard word.allSatisfy({ $0.isLetter }) else { return }

        let nsWord = word as NSString
        let range = NSRange(location: 0, length: nsWord.length)
        let misspelledRange = textChecker.rangeOfMisspelledWord(
            in: word,
            range: range,
            startingAt: 0,
            wrap: false,
            language: "en_US"
        )

        // No misspelling found — nothing to do.
        guard misspelledRange.location != NSNotFound else { return }

        // Get top suggestion.
        guard let suggestions = textChecker.guesses(
            forWordRange: misspelledRange,
            in: word,
            language: "en_US"
        ), let top = suggestions.first else { return }

        // Skip if suggestion is identical or radically different
        // (avoid annoying autocorrects).
        guard top.lowercased() != word.lowercased() else { return }
        guard abs(top.count - word.count) <= 3 else { return }

        // Delete the wrong word and type the corrected version.
        for _ in 0..<word.count {
            onDeleteBackward?()
        }
        onInsertText?(top)
    }

    /// Manually trigger AI cleanup on the entire current text field.
    /// Reads all text, sends to Claude, replaces in place.
    func runManualAICleanup() {
        cleanupTypedText()
    }

    // MARK: - Lifecycle

    func requestKeyboardSwitch() {
        onRequestKeyboardSwitch?()
    }

    func toggle() {
        Task { @MainActor in
            if isRecording { await stop() } else { await start() }
        }
    }

    // MARK: - Chunked dictation

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

        // Request mic permission separately — required for the
        // keyboard extension process (not inherited from main app).
        let micOK: Bool = await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        guard micOK else {
            errorMessage = "Microphone permission denied."
            return
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            return
        }

        liveTranscript = ""
        errorMessage = nil

        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord with default mode is most compatible
            // for keyboard extensions. .record alone often fails.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActive = true
        } catch {
            errorMessage = "Audio session: \(error.localizedDescription)"
            return
        }

        // Start the first recorder.
        usingRecorderA = true
        guard startRecorder(useA: true) else {
            errorMessage = "Could not start recorder."
            return
        }
        isRecording = true
        scheduleChunkRotation()
        scheduleMetering()
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        chunkTimer?.invalidate()
        chunkTimer = nil
        meteringTimer?.invalidate()
        meteringTimer = nil

        // Stop the active recorder and transcribe its final chunk.
        let finalRecorder = activeRecorder
        let finalURL = finalRecorder?.url
        finalRecorder?.stop()
        recorderA = nil
        recorderB = nil

        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false)
            sessionActive = false
        }
        audioLevel = 0

        // Process the final chunk synchronously so the user sees
        // their last words before we finish.
        if let url = finalURL {
            await processChunk(url: url)
        }
    }

    /// Start one of the two alternating recorders writing to a fresh
    /// temp file. Returns true on success.
    @discardableResult
    private func startRecorder(useA: Bool) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("vfk-\(UUID().uuidString).caf")
        // CAF + Linear PCM is the most compatible recording format
        // in keyboard extensions. Use 44.1kHz which iOS hardware
        // always supports.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else {
                errorMessage = "prepareToRecord failed"
                return false
            }
            guard recorder.record() else {
                errorMessage = "record() returned false — check mic permission"
                return false
            }
            if useA {
                recorderA = recorder
            } else {
                recorderB = recorder
            }
            return true
        } catch let nsErr as NSError {
            errorMessage = "Recorder init: \(nsErr.code) \(nsErr.localizedDescription)"
            return false
        }
    }

    /// Every chunkDuration seconds: stop the active recorder, swap
    /// to the other one (already started just before the swap),
    /// and process the just-finished chunk in parallel.
    private func scheduleChunkRotation() {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(
            withTimeInterval: chunkDuration,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rotateChunk()
            }
        }
    }

    private func rotateChunk() {
        guard isRecording else { return }

        // Capture the current recorder + URL before swapping.
        let oldRecorder = activeRecorder
        let oldURL = oldRecorder?.url

        // Start the OTHER recorder first to minimize the audio gap.
        let nextUseA = !usingRecorderA
        guard startRecorder(useA: nextUseA) else { return }

        // Swap active recorder.
        usingRecorderA = nextUseA

        // Stop the old recorder.
        oldRecorder?.stop()
        if usingRecorderA {
            recorderB = nil
        } else {
            recorderA = nil
        }

        // Process the just-finished chunk in the background.
        if let url = oldURL {
            Task.detached { [weak self] in
                await self?.processChunk(url: url)
            }
        }
    }

    /// Transcribe a chunk file, run Haiku cleanup, insert at cursor.
    private func processChunk(url: URL) async {
        guard let recognizer = speechRecognizer else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let raw = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if #available(iOS 16.0, *) {
                request.addsPunctuation = true
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    print("[VFKB] chunk transcribe error: \(error.localizedDescription)")
                    cont.resume(returning: "")
                    return
                }
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }

        try? FileManager.default.removeItem(at: url)

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Run through Haiku cleanup with prompt caching for speed.
        let cleanRequest = ClaudeCleanup.Request(
            rawTranscript: trimmed,
            tone: tonePreset,
            packPromptHints: nil,
            packTermsBlock: nil,
            model: .haiku
        )

        let textToInsert: String
        do {
            textToInsert = try await ClaudeCleanup.shared.clean(cleanRequest)
        } catch {
            textToInsert = trimmed
        }

        // Insert with a leading space to separate from previous chunk.
        await MainActor.run {
            let prefix = liveTranscript.isEmpty ? "" : " "
            let final = prefix + textToInsert
            onInsertText?(final)
            liveTranscript += final
        }
    }

    /// Poll active recorder for audio levels (waveform + silence).
    private func scheduleMetering() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let r = self.activeRecorder else { return }
                r.updateMeters()
                let avg = r.averagePower(forChannel: 0)
                self.audioLevel = max(0, (avg + 60) / 60)
            }
        }
    }

    // MARK: - Polish + insert (legacy non-chunked path, retained
    //  for compatibility but unused in chunked mode)

    private func polishAndInsert(raw: String) async {
        // No-op in chunked mode — chunks are polished individually.
    }
}
