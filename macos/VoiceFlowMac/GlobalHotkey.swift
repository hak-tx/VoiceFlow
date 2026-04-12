//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Double-tap Control (^) to toggle dictation globally.
//
//  Uses CGEventTap at the HID level — the most reliable way to
//  detect modifier-only key events on macOS. NSEvent monitors miss
//  flagsChanged events in many scenarios.
//
//  Requires Accessibility permissions (System Settings → Privacy
//  & Security → Accessibility).
//

import AppKit
import CoreGraphics

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    weak var engine: MacDictationEngine?

    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var hasAccessibilityPermission: Bool = false

    var doubleTapInterval: TimeInterval = 0.4

    // Stored as nonisolated state accessed from the CGEvent callback.
    // The callback runs on a background runloop, so we use a simple
    // lock-free approach: the callback writes timestamps and the
    // main actor reads them via a timer.
    private static var lastControlDownTime: CFAbsoluteTime = 0
    private static var controlWasDown: Bool = false
    private static var shouldToggle: Bool = false
    private static var configuredInterval: TimeInterval = 0.4

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?

    init() {
        checkAccessibilityPermission()
    }

    deinit {
        unregister()
    }

    func register() {
        unregister()

        Self.configuredInterval = doubleTapInterval

        // Create a CGEvent tap for flagsChanged events.
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,  // don't block events
            eventsOfInterest: mask,
            callback: globalHotkeyCallback,
            userInfo: nil
        ) else {
            // Tap creation failed — no Accessibility permission.
            hasAccessibilityPermission = false
            return
        }

        eventTap = tap
        hasAccessibilityPermission = true

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Poll for toggle requests from the callback (which runs
        // on a non-main-actor context).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if Self.shouldToggle {
                    Self.shouldToggle = false
                    self?.engine?.toggle()
                }
            }
        }

        isRegistered = true
    }

    func unregister() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        isRegistered = false
    }

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        hasAccessibilityPermission = trusted
        if trusted && !isRegistered {
            register()
        }
    }
}

// C-function callback for CGEvent tap — runs outside MainActor.
private func globalHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard type == .flagsChanged else {
        return Unmanaged.passRetained(event)
    }

    let flags = CGEventFlags(rawValue: event.flags.rawValue)
    let controlNow = flags.contains(.maskControl)
    let hasOthers = !flags.intersection([.maskCommand, .maskAlternate, .maskShift]).isEmpty

    if controlNow && !GlobalHotkeyManager.controlWasDown && !hasOthers {
        GlobalHotkeyManager.controlWasDown = true
        let now = CFAbsoluteTimeGetCurrent()
        let last = GlobalHotkeyManager.lastControlDownTime
        let interval = GlobalHotkeyManager.configuredInterval

        if (now - last) <= interval && last > 0 {
            GlobalHotkeyManager.shouldToggle = true
            GlobalHotkeyManager.lastControlDownTime = 0
        } else {
            GlobalHotkeyManager.lastControlDownTime = now
        }
    } else if !controlNow && GlobalHotkeyManager.controlWasDown {
        GlobalHotkeyManager.controlWasDown = false
    }

    return Unmanaged.passRetained(event)
}
