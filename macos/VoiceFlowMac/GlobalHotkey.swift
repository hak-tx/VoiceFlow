//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Double-tap Control (^) to toggle dictation.
//

import AppKit

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    weak var engine: MacDictationEngine?

    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var hasAccessibilityPermission: Bool = false

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var lastControlPress: Date?
    private var controlDown: Bool = false
    private let interval: TimeInterval = 0.4

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

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }

        isRegistered = true
    }

    func unregister() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        isRegistered = false
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }

        let ctrl = event.modifierFlags.contains(.control)
        let others = event.modifierFlags.intersection([.command, .option, .shift])

        if ctrl && !controlDown && others.isEmpty {
            controlDown = true
            let now = Date()
            if let last = lastControlPress, now.timeIntervalSince(last) < interval {
                lastControlPress = nil
                engine?.toggle()
            } else {
                lastControlPress = now
            }
        } else if !ctrl {
            controlDown = false
        }
    }

    func checkAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(opts)
    }
}
