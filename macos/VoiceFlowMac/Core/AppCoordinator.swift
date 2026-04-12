//
//  AppCoordinator.swift
//  VoiceFlowMac
//
//  Core dictation flow:
//    1. ⌃⌃ → recording starts, overlay shows live transcript
//    2. User speaks → transcript updates in overlay
//    3. ⌃⌃ → stops, sends to Claude Haiku for cleanup
//    4. Cleaned text inserted at cursor via single Cmd+V paste
//
//  Text is NOT streamed to the cursor during recording. That approach
//  (AX replaceRange on every partial result) is unreliable — causes
//  duplication, doesn't work in all apps, and race-condition-prone.
//  Instead, the user sees their live transcript in the overlay, and
//  the final cleaned result is pasted once.
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
            Task { @MainActor in await self.hotkeyPressed() }
        }

        hotkeyManager.onDeactivate = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.hotkeyPressed() }
        }

        engine.onPolishComplete = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in self.handlePolishComplete(text) }
        }

        engine.onSilenceDetected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.stopAndClean() }
        }

        hotkeyManager.install()

        Task {
            await vocabManager.loadInstalledPacks()
            log.info("Loaded \(self.vocabManager.installedPacks.count) packs, \(self.vocabManager.activePackNames.count) active")
        }
    }

    // MARK: - Hotkey toggle

    private func hotkeyPressed() async {
        if engine.isRecording {
            await stopAndClean()
        } else {
            await startRecording()
        }
    }

    // MARK: - Start

    private func startRecording() async {
        log.info("Starting dictation")
        lastPolishError = nil
        statusMessage = nil

        // Capture cursor position for the overlay placement.
        accessibilityManager.captureCurrentContext()

        await engine.start()

        // Show overlay near cursor with live transcript.
        overlayController.show(
            near: accessibilityManager.cursorRect,
            engine: engine,
            settings: settings
        )
    }

    // MARK: - Stop and clean

    private func stopAndClean() async {
        log.info("Stopping dictation — sending to Claude")
        await engine.stop()
        // engine.stop() calls polish() internally, which triggers
        // onPolishComplete when done.
    }

    // MARK: - Polish complete → paste at cursor

    private func handlePolishComplete(_ text: String) {
        log.info("Polish complete — \(text.count) chars")

        guard !text.isEmpty else {
            log.warning("Polish returned empty text")
            overlayController.dismiss()
            hotkeyManager.deactivate()
            return
        }

        // Copy to clipboard.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Paste at cursor with Cmd+V.
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        statusMessage = "Pasted at cursor"
        log.info("Text pasted via Cmd+V")

        if settings.playSoundEffects {
            NSSound(named: "Blow")?.play()
        }

        // Dismiss overlay after brief delay.
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            overlayController.dismiss()
            hotkeyManager.deactivate()
        }
    }

    // MARK: - Popover mic button

    func startFromPopover() async {
        log.info("Starting from popover")
        lastPolishError = nil
        statusMessage = nil
        await engine.start()
    }

    func stopFromPopover() async {
        await stopAndClean()
    }

    // MARK: - Retry

    func retryPolish() async {
        guard !engine.liveTranscript.isEmpty else { return }
        lastPolishError = nil
        await engine.polish()
        if engine.errorMessage != nil {
            lastPolishError = engine.errorMessage
        }
    }
}
