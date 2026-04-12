//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Global hotkey: Cmd+Shift+D to toggle dictation.
//  Simple NSEvent monitors — the approach that worked.
//

import AppKit

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    weak var engine: MacDictationEngine?
    @Published private(set) var isRegistered: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func setup() {
        guard !isRegistered else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKey(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKey(event)
            }
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

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }
}
