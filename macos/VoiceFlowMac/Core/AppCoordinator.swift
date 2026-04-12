//
//  AppCoordinator.swift
//  VoiceFlowMac
//
//  Two modes of operation:
//
//  WITHOUT Accessibility (default, works immediately):
//    1. Click mic in popover → dictation starts
//    2. Speak → live transcript shows in popover
//    3. Click stop → Claude cleans up
//    4. Cleaned text auto-copied to clipboard
//    5. User pastes with ⌘V wherever they want
//
//  WITH Accessibility (when permission is granted):
//    1. ⌃⌃ hotkey starts dictation from anywhere
//    2. Text streams live at the cursor
//    3. ⌃⌃ again stops → Claude cleans and replaces in-place
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
    @Published private(set) var isRetrying = false

    /// Status message shown in the popover after polish completes.
    @Published var statusMessage: String?

    // Live typing state (only used when Accessibility is available)
    private var insertedCharCount: Int = 0
    private var insertionStart: Int = 0
    private var transcriptObserver: AnyCancellable?
    private var isLiveTypingActive = false

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

        // Wire hotkey (only works with Accessibility)
        hotkeyManager.onActivate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.startWithHotkey() }
        }
        hotkeyManager.onDeactivate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.stopDictation() }
        }

        // Polish complete → copy to clipboard (always), insert at
        // cursor (only if Accessibility + live typing active)
        engine.onPolishComplete = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in self.handlePolishComplete(text) }
        }

        engine.onSilenceDetected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.stopDictation() }
        }

        // Try to install hotkey (will silently fail without Accessibility)
        hotkeyManager.install()

        if !hotkeyManager.hasAccessibilityPermission {
            log.info("No Accessibility — running in clipboard mode")
        } else {
            log.info("Accessibility granted — hotkey + cursor mode active")
        }

        Task {
            await vocabManager.loadInstalledPacks()
            log.info("Loaded \(self.vocabManager.installedPacks.count) vocab packs")
        }
    }

    // MARK: - Start dictation from hotkey (with Accessibility)

    private func startWithHotkey() async {
        log.info("Hotkey activated")
        lastPolishError = nil
        statusMessage = nil

        accessibilityManager.captureCurrentContext()
        insertionStart = accessibilityManager.selectedRange.location
        insertedCharCount = 0

        if !accessibilityManager.selectedText.isEmpty {
            let ctx = accessibilityManager.surroundingContext()
            let range = NSRange(
                location: accessibilityManager.selectedRange.location,
                length: accessibilityManager.selectedRange.length
            )
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

        startLiveTyping()
        isLiveTypingActive = true

        overlayController.show(
            near: accessibilityManager.cursorRect,
            engine: engine,
            settings: settings
        )
    }

    // MARK: - Start dictation from mic button (no Accessibility needed)

    func startFromPopover() async {
        log.info("Starting dictation from popover (clipboard mode)")
        lastPolishError = nil
        statusMessage = nil
        isLiveTypingActive = false
        await engine.start()
    }

    // MARK: - Stop dictation

    func stopDictation() async {
        log.info("Stopping dictation")
        stopLiveTyping()
        await engine.stop()
    }

    // MARK: - Live typing (Accessibility mode only)

    private func startLiveTyping() {
        transcriptObserver = engine.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTranscript in
                guard let self, self.engine.isRecording, self.isLiveTypingActive else { return }
                self.pushToCursor(newTranscript)
            }
    }

    private func stopLiveTyping() {
        transcriptObserver?.cancel()
        transcriptObserver = nil
    }

    private func pushToCursor(_ fullTranscript: String) {
        if insertedCharCount > 0 {
            let replaceRange = CFRange(
                location: insertionStart,
                length: insertedCharCount
            )
            accessibilityManager.replaceRange(replaceRange, with: fullTranscript)
        } else if !fullTranscript.isEmpty {
            accessibilityManager.insertText(fullTranscript)
        }
        insertedCharCount = fullTranscript.count
    }

    // MARK: - Polish complete

    private func handlePolishComplete(_ text: String) {
        log.info("Polish complete — \(text.count) chars")

        if isLiveTypingActive {
            // Replace raw text at cursor with cleaned version
            let replaceRange = CFRange(
                location: insertionStart,
                length: insertedCharCount
            )
            accessibilityManager.replaceRange(replaceRange, with: text)
            insertedCharCount = text.count
        }

        // ALWAYS copy to clipboard regardless of mode
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied to clipboard — paste with ⌘V"
        log.info("Cleaned text copied to clipboard")

        if settings.playSoundEffects {
            NSSound(named: "Blow")?.play()
        }

        if isLiveTypingActive {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                overlayController.dismiss()
                hotkeyManager.deactivate()
            }
        }

        isLiveTypingActive = false
    }

    // MARK: - Retry

    func retryPolish() async {
        guard !engine.liveTranscript.isEmpty else { return }
        isRetrying = true
        lastPolishError = nil
        await engine.polish()
        isRetrying = false
        if engine.errorMessage != nil {
            lastPolishError = engine.errorMessage
        }
    }
}
