//
//  AppCoordinator.swift
//  VoiceFlowMac
//
//  Single point of truth for app-level wiring and lifecycle.
//
//  Core UX flow:
//    1. User presses ⌃⌃ — dictation starts
//    2. Live text streams directly at the cursor in whatever app
//       the user is in (not in VoiceFlow's UI)
//    3. User presses ⌃⌃ again — dictation stops
//    4. Raw text at the cursor is replaced with LLM-cleaned version
//
//  The menu bar popover is for settings only, not for transcript display.
//

import Foundation
import AppKit
import Combine
import os.log

private let log = Logger(subsystem: "com.hak-tx.voiceflow.mac", category: "Coordinator")

@MainActor
final class AppCoordinator: ObservableObject {

    // MARK: - Owned managers

    let settings: MacAppSettings
    let engine: MacDictationEngine
    let vocabManager: MacVocabPackManager
    let hotkeyManager: GlobalHotkeyManager
    let overlayController: OverlayPanelController
    let accessibilityManager: AccessibilityTextManager

    @Published private(set) var isSetupComplete = false
    @Published var lastPolishError: String?
    @Published private(set) var isRetrying = false

    // MARK: - Live typing state

    /// Tracks how many characters of raw transcript we've already
    /// typed into the target app. On each transcript update, we only
    /// type the NEW characters (the delta) so we don't retype everything.
    private var insertedCharCount: Int = 0

    /// The cursor position where we started inserting. Used to select
    /// and replace the raw text with the polished version.
    private var insertionStart: Int = 0

    /// Observe liveTranscript changes to stream text to cursor.
    private var transcriptObserver: AnyCancellable?

    // MARK: - Init

    init() {
        self.settings = MacAppSettings()
        self.engine = MacDictationEngine()
        self.vocabManager = MacVocabPackManager()
        self.hotkeyManager = GlobalHotkeyManager()
        self.overlayController = OverlayPanelController()
        self.accessibilityManager = AccessibilityTextManager()
    }

    // MARK: - One-time setup

    func setup() {
        guard !isSetupComplete else {
            log.warning("setup() called more than once — ignoring")
            return
        }
        isSetupComplete = true
        log.info("AppCoordinator.setup() — wiring dependencies")

        engine.vocabManager = vocabManager
        engine.settings = settings
        engine.silenceThreshold = settings.silenceAutoStopSeconds

        // Wire hotkey → dictation pipeline.
        hotkeyManager.onActivate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHotkeyActivate()
            }
        }

        hotkeyManager.onDeactivate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHotkeyDeactivate()
            }
        }

        // Wire polish complete → replace raw text with cleaned version.
        engine.onPolishComplete = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.handlePolishComplete(text)
            }
        }

        // Wire silence auto-stop.
        engine.onSilenceDetected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                log.info("Silence detected — auto-stopping")
                await self.engine.stop()
            }
        }

        hotkeyManager.install()

        // Auto-prompt for Accessibility permission on first launch.
        if !hotkeyManager.hasAccessibilityPermission {
            log.info("Accessibility not granted — prompting user")
            hotkeyManager.requestAccessibilityPermission()
        }

        Task {
            await vocabManager.loadInstalledPacks()
            log.info("Loaded \(self.vocabManager.installedPacks.count) vocab packs")
        }
    }

    // MARK: - Hotkey handlers

    private func handleHotkeyActivate() async {
        log.info("Hotkey activated — starting dictation")
        lastPolishError = nil

        // Snapshot cursor position.
        accessibilityManager.captureCurrentContext()

        // Remember where we're starting to type.
        insertionStart = accessibilityManager.selectedRange.location
        insertedCharCount = 0

        // If there's selected text, we'll replace it.
        if !accessibilityManager.selectedText.isEmpty {
            log.info("Selection detected (\(self.accessibilityManager.selectedText.count) chars) — will replace on completion")
            let ctx = accessibilityManager.surroundingContext()
            let range = NSRange(
                location: accessibilityManager.selectedRange.location,
                length: accessibilityManager.selectedRange.length
            )
            // Delete the selected text first — we'll type fresh.
            accessibilityManager.insertText("")
            await engine.startReplacingSelection(
                in: accessibilityManager.fullText,
                range: range,
                before: ctx.before,
                after: ctx.after
            )
        } else {
            await engine.start()
        }

        // Start observing transcript changes to stream text at cursor.
        startLiveTyping()

        // Show a minimal overlay (just recording indicator, not transcript).
        overlayController.show(
            near: accessibilityManager.cursorRect,
            engine: engine,
            settings: settings
        )
    }

    private func handleHotkeyDeactivate() async {
        log.info("Hotkey deactivated — stopping dictation")

        // Stop observing transcript so we don't type during polish.
        stopLiveTyping()

        await engine.stop()
    }

    // MARK: - Live typing at cursor

    /// Watch engine.liveTranscript and type new characters at the
    /// cursor in real-time as the user speaks.
    private func startLiveTyping() {
        transcriptObserver = engine.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTranscript in
                guard let self, self.engine.isRecording else { return }
                self.pushToCursor(newTranscript)
            }
    }

    private func stopLiveTyping() {
        transcriptObserver?.cancel()
        transcriptObserver = nil
    }

    /// Push the full transcript to the cursor position, replacing
    /// whatever we previously inserted. We do NOT use deltas because
    /// the speech recognizer revises earlier words as it gets more
    /// context (e.g., "Testing test" → "Testing testing"). Delta
    /// appending would duplicate text in that case.
    private func pushToCursor(_ fullTranscript: String) {
        if insertedCharCount > 0 {
            // Replace everything we've typed so far with the updated transcript.
            let replaceRange = CFRange(
                location: insertionStart,
                length: insertedCharCount
            )
            accessibilityManager.replaceRange(replaceRange, with: fullTranscript)
        } else if !fullTranscript.isEmpty {
            // First insert.
            accessibilityManager.insertText(fullTranscript)
        }
        insertedCharCount = fullTranscript.count
    }

    // MARK: - Polish complete handler

    private func handlePolishComplete(_ text: String) {
        log.info("Polish complete — \(text.count) chars, replacing \(self.insertedCharCount) raw chars")

        // Select the raw text we typed and replace with cleaned version.
        let replaceRange = CFRange(
            location: insertionStart,
            length: insertedCharCount
        )
        accessibilityManager.replaceRange(replaceRange, with: text)
        insertedCharCount = text.count

        if settings.playSoundEffects {
            NSSound(named: "Blow")?.play()
        }

        // Dismiss overlay.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            overlayController.dismiss()
            hotkeyManager.deactivate()
        }
    }

    // MARK: - Retry logic

    func retryPolish() async {
        guard !engine.liveTranscript.isEmpty else { return }
        isRetrying = true
        lastPolishError = nil
        log.info("Retrying polish...")
        await engine.polish()
        isRetrying = false
        if engine.errorMessage != nil {
            lastPolishError = engine.errorMessage
        }
    }

    // MARK: - Manual start/stop (from menu bar UI)

    /// Start dictation from the menu bar mic button. Dismisses the
    /// popover first so focus returns to whatever app the user was
    /// in, then captures cursor position and begins recording.
    func startDictationManually() async {
        // Dismiss the menu bar popover so focus goes back to the
        // user's target app. Without this, the AX API reads the
        // popover's text fields instead of the target app's.
        NSApp.keyWindow?.close()

        // Wait for focus to actually transfer back.
        try? await Task.sleep(nanoseconds: 300_000_000)

        await handleHotkeyActivate()
    }

    func stopDictationManually() async {
        await handleHotkeyDeactivate()
    }
}
