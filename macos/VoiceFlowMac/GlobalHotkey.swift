//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Cmd+Shift+D to toggle dictation. Uses keyDown events only —
//  NO flagsChanged monitoring, which was interfering with macOS's
//  native Fn double-tap dictation.
//

import AppKit

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    weak var engine: MacDictationEngine?

    @Published private(set) var isRegistered: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        register()
    }

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    func register() {
        // keyDown ONLY — not flagsChanged. flagsChanged monitors
        // intercept ALL modifier events system-wide and break
        // macOS's native Fn double-tap dictation.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
            return event
        }
        isRegistered = true
    }

    private func handleKey(_ event: NSEvent) {
        guard event.modifierFlags.contains([.command, .shift]),
              event.charactersIgnoringModifiers?.lowercased() == "d" else {
            return
        }
        engine?.toggle()
    }
}
