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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?

    init() {
        checkAccessibilityPermission()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        pollTimer?.invalidate()
    }

    func register() {
        unregister()

        HotkeyState.configuredInterval = doubleTapInterval

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
                if HotkeyState.shouldToggle {
                    HotkeyState.shouldToggle = false
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

// Shared mutable state bridging the CGEvent callback (which runs on
// a background runloop, outside MainActor) and the MainActor poll
// timer. Simple value types — no lock needed for this use case.
enum HotkeyState {
    nonisolated(unsafe) static var lastControlDownTime: CFAbsoluteTime = 0
    nonisolated(unsafe) static var controlWasDown: Bool = false
    nonisolated(unsafe) static var shouldToggle: Bool = false
    nonisolated(unsafe) static var configuredInterval: TimeInterval = 0.4
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

    if controlNow && !HotkeyState.controlWasDown && !hasOthers {
        HotkeyState.controlWasDown = true
        let now = CFAbsoluteTimeGetCurrent()
        let last = HotkeyState.lastControlDownTime
        let interval = HotkeyState.configuredInterval

        if (now - last) <= interval && last > 0 {
            HotkeyState.shouldToggle = true
            HotkeyState.lastControlDownTime = 0
        } else {
            HotkeyState.lastControlDownTime = now
        }
    } else if !controlNow && HotkeyState.controlWasDown {
        HotkeyState.controlWasDown = false
    }

    return Unmanaged.passRetained(event)
}
