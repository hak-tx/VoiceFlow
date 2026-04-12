//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Registers Cmd+Shift+D as a global hotkey to start/stop dictation
//  from anywhere on macOS.
//
//  Uses NSEvent.addGlobalMonitorForEvents for key-down events. This
//  requires the app to have Accessibility permissions granted by the
//  user in System Settings > Privacy & Security > Accessibility.
//
//  Note: addGlobalMonitorForEvents only receives events when THIS app
//  is NOT the frontmost app. For events while the app is frontmost we
//  also install a local monitor.
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

    init() {
        checkAccessibilityPermission()
        register()
    }

    deinit {
        // Cannot call MainActor methods in deinit directly; just nil them out.
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    // MARK: - Register / Unregister

    func register() {
        unregister()

        // Global monitor: fires when another app is frontmost
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
        }

        // Local monitor: fires when this app is frontmost
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyEvent(event)
            }
            // Return the event so other responders still see it.
            // If we consumed it (Cmd+Shift+D), we could return nil,
            // but it's safer to let it pass through for menu-bar apps.
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

    // MARK: - Event handling

    private func handleKeyEvent(_ event: NSEvent) {
        // Check for Cmd+Shift+D
        guard event.modifierFlags.contains([.command, .shift]),
              event.charactersIgnoringModifiers?.lowercased() == "d" else {
            return
        }

        engine?.toggle()
    }

    // MARK: - Accessibility check

    func checkAccessibilityPermission() {
        // Check if we have accessibility access (required for global
        // event monitoring). This call also prompts the user the first
        // time if the `prompt` option is true.
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        hasAccessibilityPermission = trusted
    }
}
