//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Detects a double-tap of the Control (^) key to toggle dictation.
//  Works globally — even when another app is frontmost.
//
//  How it works: monitors NSEvent.flagsChanged for the .control
//  modifier. When Control is pressed twice within 0.4s, it fires.
//  This mirrors the UX of macOS dictation (double-tap Fn) and
//  feels natural for power users.
//
//  Requires Accessibility permissions (System Settings → Privacy
//  & Security → Accessibility).
//

import AppKit
import Combine

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    /// The engine to toggle when the hotkey fires.
    weak var engine: MacDictationEngine?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Whether the hotkey is currently registered.
    @Published private(set) var isRegistered: Bool = false

    /// Accessibility permission status.
    @Published private(set) var hasAccessibilityPermission: Bool = false

    /// Maximum interval between two Control taps to count as a
    /// double-tap. Configurable via UserDefaults if we add a
    /// settings UI later.
    var doubleTapInterval: TimeInterval = 0.4

    /// Timestamp of the last Control key-down.
    private var lastControlDown: Date?

    /// Track whether Control is currently held so we only count
    /// distinct press events, not repeats.
    private var controlIsDown: Bool = false

    init() {
        checkAccessibilityPermission()
        register()
    }

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    // MARK: - Register / Unregister

    func register() {
        unregister()

        // Monitor flagsChanged (modifier key press/release) instead
        // of keyDown — Control by itself doesn't generate keyDown.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        isRegistered = true
    }

    func unregister() {
        if let g = globalMonitor {
            NSEvent.removeMonitor(g)
            globalMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
        isRegistered = false
    }

    // MARK: - Double-tap detection

    private func handleFlagsChanged(_ event: NSEvent) {
        let controlPressed = event.modifierFlags.contains(.control)

        // Only fire on press (not release), and only if no other
        // modifiers are held (so Ctrl+C etc. don't trigger).
        let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .shift]
        let hasOtherModifiers = !event.modifierFlags.intersection(otherModifiers).isEmpty

        if controlPressed && !controlIsDown && !hasOtherModifiers {
            // Control just went down (fresh press).
            controlIsDown = true

            let now = Date()
            if let last = lastControlDown,
               now.timeIntervalSince(last) <= doubleTapInterval {
                // Double-tap detected!
                lastControlDown = nil
                engine?.toggle()
            } else {
                lastControlDown = now
            }
        } else if !controlPressed && controlIsDown {
            // Control released.
            controlIsDown = false
        }
    }

    // MARK: - Accessibility check

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        hasAccessibilityPermission = trusted
    }
}
