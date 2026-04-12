//
//  AppCoordinator.swift
//  VoiceFlowMac
//
//  Flow:
//    1. ⌃⌃ → recording starts, tiny "Recording" pill appears
//    2. Text streams LIVE at the cursor as user speaks
//    3. ⌃⌃ → stops, raw text replaced with LLM-cleaned version
//
//  Text goes at the cursor. Nowhere else. The overlay is just a
//  tiny status pill — no transcript in it.
//

import Foundation
import AppKit
import Combine
import os.log

private let log = Logger(subsystem: "com.hak-tx.voiceflow.mac", category: "Coordinator")

@MainActor
final class AppCoordinator: ObservableObject {

    let settings: MacAppSettings
    let engine: MacDictationEngine
    let vocabManager: MacVocabPackManager
    let hotkeyManager: GlobalHotkeyManager
    let overlayController: OverlayPanelController
    let accessibilityManager: AccessibilityTextManager

    @Published private(set) var isSetupComplete = false
    @Published var lastPolishError: String?
    @Published var statusMessage: String?

    /// How many chars we've inserted at the cursor so far.
    private var insertedCharCount: Int = 0
    /// Where we started inserting.
    private var insertionStart: Int = 0
    /// Observe transcript changes.
    private var transcriptObserver: AnyCancellable?
    /// The focused AX element we're typing into.
    private var lastTranscriptPushed: String = ""

    init() {
        self.settings = MacAppSettings()
        self.engine = MacDictationEngine()
        self.vocabManager = MacVocabPackManager()
        self.hotkeyManager = GlobalHotkeyManager()
        self.overlayController = OverlayPanelController()
        self.accessibilityManager = AccessibilityTextManager()
    }

    func setup() {
        guard !isSetupComplete else { return }
        isSetupComplete = true
        log.info("AppCoordinator.setup()")

        engine.vocabManager = vocabManager
        engine.settings = settings
        engine.silenceThreshold = settings.silenceAutoStopSeconds

        hotkeyManager.onActivate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.hotkeyToggle() }
        }
        hotkeyManager.onDeactivate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.hotkeyToggle() }
        }

        engine.onPolishComplete = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in self.handlePolishComplete(text) }
        }

        engine.onSilenceDetected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.stopRecording() }
        }

        hotkeyManager.install()

        Task {
            await vocabManager.loadInstalledPacks()
            log.info("Loaded \(self.vocabManager.installedPacks.count) packs")
        }
    }

    // MARK: - Hotkey

    private func hotkeyToggle() async {
        if engine.isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    // MARK: - Start

    private func startRecording() async {
        log.info("Starting dictation")
        lastPolishError = nil
        statusMessage = nil
        lastTranscriptPushed = ""

        // Capture where the cursor is RIGHT NOW.
        accessibilityManager.captureCurrentContext()
        insertionStart = accessibilityManager.selectedRange.location
        insertedCharCount = 0

        await engine.start()

        // Start pushing transcript to cursor.
        startCursorStreaming()

        // Show tiny pill near cursor.
        overlayController.show(
            near: accessibilityManager.cursorRect,
            engine: engine,
            settings: settings
        )
    }

    // MARK: - Stop

    private func stopRecording() async {
        log.info("Stopping dictation")
        stopCursorStreaming()
        await engine.stop()
        // engine.stop() triggers polish(), which calls onPolishComplete
    }

    // MARK: - Stream text to cursor

    private func startCursorStreaming() {
        transcriptObserver = engine.$liveTranscript
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] transcript in
                guard let self, self.engine.isRecording else { return }
                guard transcript != self.lastTranscriptPushed else { return }
                self.streamToCursor(transcript)
                self.lastTranscriptPushed = transcript
            }
    }

    private func stopCursorStreaming() {
        transcriptObserver?.cancel()
        transcriptObserver = nil
    }

    private func streamToCursor(_ fullTranscript: String) {
        if insertedCharCount == 0 && !fullTranscript.isEmpty {
            // First insert — just type the text.
            accessibilityManager.insertTextDirect(fullTranscript)
            insertedCharCount = fullTranscript.count
            log.debug("First insert: \(fullTranscript.count) chars")
        } else if insertedCharCount > 0 {
            // Replace previously inserted text with updated transcript.
            let range = CFRange(
                location: insertionStart,
                length: insertedCharCount
            )
            let success = accessibilityManager.replaceRangeDirect(range, with: fullTranscript)
            if success {
                insertedCharCount = fullTranscript.count
            } else {
                log.warning("AX replace failed — skipping this update (no fallback)")
                // Do NOT fall back to clipboard paste. That causes duplication.
            }
        }
    }

    // MARK: - Polish complete

    private func handlePolishComplete(_ text: String) {
        log.info("Polish complete — \(text.count) chars")

        guard !text.isEmpty else {
            log.warning("Polish returned empty")
            overlayController.dismiss()
            hotkeyManager.deactivate()
            return
        }

        // Replace the raw text at cursor with cleaned version.
        if insertedCharCount > 0 {
            let range = CFRange(
                location: insertionStart,
                length: insertedCharCount
            )
            let success = accessibilityManager.replaceRangeDirect(range, with: text)
            if success {
                insertedCharCount = text.count
            } else {
                // AX failed — fall back to clipboard paste for final result only.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                simulatePaste()
                log.info("Fell back to Cmd+V for final insert")
            }
        } else {
            // Nothing was inserted during recording (maybe AX wasn't available).
            // Just paste the result.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            simulatePaste()
        }

        if settings.playSoundEffects {
            NSSound(named: "Blow")?.play()
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            overlayController.dismiss()
            hotkeyManager.deactivate()
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Popover controls

    func startFromPopover() async {
        await startRecording()
    }

    func stopFromPopover() async {
        await stopRecording()
    }

    func retryPolish() async {
        guard !engine.liveTranscript.isEmpty else { return }
        lastPolishError = nil
        await engine.polish()
        if engine.errorMessage != nil {
            lastPolishError = engine.errorMessage
        }
    }
}
