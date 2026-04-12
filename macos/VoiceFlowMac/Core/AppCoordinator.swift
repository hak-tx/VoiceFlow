//
//  AppCoordinator.swift
//  VoiceFlowMac
//
//  Single point of truth for app-level wiring and lifecycle. This
//  runs exactly ONCE on app launch — not on every popover open like
//  the previous MenuBarView.onAppear approach.
//
//  Responsibilities:
//    - Wire dependencies between all managers
//    - Set up hotkey → dictation → overlay → text insertion pipeline
//    - Handle the full dictation lifecycle (start → record → stop →
//      polish → insert)
//    - Manage error recovery and retry logic
//
//  This is the class that ties everything together. If you need to
//  understand the full flow, start here.
//

import Foundation
import AppKit
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

    /// True once `setup()` has been called. Prevents double-wiring.
    @Published private(set) var isSetupComplete = false

    /// The last polish result, kept for retry if the user wants to
    /// re-attempt a failed cleanup.
    @Published var lastPolishError: String?

    /// True while a retry is in progress.
    @Published private(set) var isRetrying = false

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

    /// Call exactly once from the app's root view `.task {}`.
    /// Wires all dependencies and installs the global hotkey.
    func setup() {
        guard !isSetupComplete else {
            log.warning("setup() called more than once — ignoring")
            return
        }
        isSetupComplete = true

        log.info("AppCoordinator.setup() — wiring dependencies")

        // Wire engine collaborators.
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

        // Wire polish complete → text insertion.
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

        // Install the global hotkey listener.
        hotkeyManager.install()

        // Load vocab packs.
        Task {
            await vocabManager.loadInstalledPacks()
            log.info("Loaded \(self.vocabManager.installedPacks.count) vocab packs")
        }
    }

    // MARK: - Hotkey handlers

    private func handleHotkeyActivate() async {
        log.info("Hotkey activated — starting dictation")
        lastPolishError = nil

        // Snapshot what's at the cursor.
        accessibilityManager.captureCurrentContext()

        // If there's selected text, enter replace mode.
        if !accessibilityManager.selectedText.isEmpty {
            log.info("Selection detected (\(self.accessibilityManager.selectedText.count) chars) — entering replace mode")
            let ctx = accessibilityManager.surroundingContext()
            let range = NSRange(
                location: accessibilityManager.selectedRange.location,
                length: accessibilityManager.selectedRange.length
            )
            await engine.startReplacingSelection(
                in: accessibilityManager.fullText,
                range: range,
                before: ctx.before,
                after: ctx.after
            )
        } else {
            await engine.start()
        }

        // Show the overlay near the cursor.
        overlayController.show(
            near: accessibilityManager.cursorRect,
            engine: engine,
            settings: settings
        )
    }

    private func handleHotkeyDeactivate() async {
        log.info("Hotkey deactivated — stopping dictation")
        await engine.stop()
        // Polish is kicked off inside engine.stop(). The
        // onPolishComplete callback handles the rest.
    }

    // MARK: - Polish complete handler

    private func handlePolishComplete(_ text: String) {
        log.info("Polish complete — \(text.count) chars")

        if settings.autoInsertAfterPolish {
            accessibilityManager.insertText(text)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            log.info("Copied polished text to clipboard (auto-insert disabled)")
        }

        if settings.playSoundEffects {
            NSSound(named: "Blow")?.play()
        }

        // Brief delay so the user sees "DONE" in the overlay, then dismiss.
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            overlayController.dismiss()
            hotkeyManager.deactivate()
        }
    }

    // MARK: - Retry logic

    /// Retry the last failed polish. Called from the UI when the
    /// user taps "Retry" after a network error.
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

    func startDictationManually() async {
        lastPolishError = nil
        accessibilityManager.captureCurrentContext()

        if !accessibilityManager.selectedText.isEmpty {
            let ctx = accessibilityManager.surroundingContext()
            let range = NSRange(
                location: accessibilityManager.selectedRange.location,
                length: accessibilityManager.selectedRange.length
            )
            await engine.startReplacingSelection(
                in: accessibilityManager.fullText,
                range: range,
                before: ctx.before,
                after: ctx.after
            )
        } else {
            await engine.start()
        }
    }

    func stopDictationManually() async {
        await engine.stop()
    }
}
