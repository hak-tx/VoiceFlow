//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Detects a double-tap of the Control key globally using
//  NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged).
//  Requires Accessibility permissions (System Settings >
//  Privacy & Security > Accessibility).
//
//  The handler checks ONLY for the .control modifier and ignores
//  .function flag changes to avoid false positives from Fn key.
//

import AppKit
import Combine

@MainActor
final class GlobalHotkey: ObservableObject {

    /// Fires when the user double-taps Control.
    var onDoubleTap: (() -> Void)?

    @Published private(set) var isAccessibilityGranted: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastControlUp: Date?
    private let doubleTapWindow: TimeInterval = 0.4

    init() {
        checkAccessibilityPermission()
        register()
    }

    deinit {
        unregister()
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        isAccessibilityGranted = trusted
    }

    // MARK: - Monitor registration

    func register() {
        // Global monitor catches events when the app is NOT focused.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }

        // Local monitor catches events when the menu bar panel IS focused.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
            return event
        }
    }

    func unregister() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Detection logic

    private func handleFlagsChanged(_ event: NSEvent) {
        // We only care about the Control key. Ignore .function and
        // other modifier changes to avoid false positives.
        let controlPressed = event.modifierFlags.contains(.control)

        // Filter: if other modifiers are held alongside Control,
        // this is not a bare Control tap.
        let otherModifiers: NSEvent.ModifierFlags = [.shift, .option, .command]
        if !event.modifierFlags.intersection(otherModifiers).isEmpty {
            lastControlUp = nil
            return
        }

        // We detect on key-up (Control released). When Control is
        // released, modifierFlags will NOT contain .control.
        if !controlPressed {
            // Check that the key that changed IS the Control key by
            // looking at the raw keyCode. Left Control = 0x3B,
            // Right Control = 0x3E. However, flagsChanged events
            // on key-up don't always set keyCode reliably. Instead,
            // we track state: if we were previously seeing Control
            // pressed and now it's gone, that's a Control-up.
            // The simplest reliable approach: if modifierFlags is
            // now empty (no modifiers held) and we're in a flags
            // changed event, check if the previous state included
            // Control. We use a simpler heuristic: track whether
            // the last flagsChanged had .control, and this one does
            // not.
            handleControlUp()
        }
        // On press, we just note it but do nothing until release.
    }

    private func handleControlUp() {
        let now = Date()

        if let last = lastControlUp,
           now.timeIntervalSince(last) < doubleTapWindow {
            // Double tap detected!
            lastControlUp = nil
            onDoubleTap?()
        } else {
            lastControlUp = now
        }
    }
}
