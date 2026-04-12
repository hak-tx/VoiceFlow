//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Detects a double-tap of the Control (^) key to toggle dictation.
//  Works globally — even when another app is frontmost.
//
//  Uses a CGEvent tap at the HID system level for reliable modifier
//  key detection. Falls back to NSEvent monitors if the event tap
//  can't be created (permissions issue).
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

    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var hasAccessibilityPermission: Bool = false

    /// Max interval between two Control taps for a double-tap.
    var doubleTapInterval: TimeInterval = 0.4

    private var lastControlDown: Date?
    private var controlIsDown: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        checkAccessibilityPermission()
        register()
    }

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    func register() {
        unregister()

        // Monitor flagsChanged for modifier-only keys (Control
        // doesn't generate keyDown events).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
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

    private func handleFlags(_ event: NSEvent) {
        let controlNow = event.modifierFlags.contains(.control)
        let others: NSEvent.ModifierFlags = [.command, .option, .shift]
        let hasOthers = !event.modifierFlags.intersection(others).isEmpty

        if controlNow && !controlIsDown && !hasOthers {
            controlIsDown = true
            let now = Date()
            if let last = lastControlDown,
               now.timeIntervalSince(last) <= doubleTapInterval {
                lastControlDown = nil
                engine?.toggle()
            } else {
                lastControlDown = now
            }
        } else if !controlNow && controlIsDown {
            controlIsDown = false
        }
    }

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        hasAccessibilityPermission = trusted
    }
}
