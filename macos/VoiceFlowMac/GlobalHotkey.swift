//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Double-tap Control (^) to toggle dictation globally.
//  Tries CGEventTap first (most reliable), falls back to NSEvent
//  monitors if the tap can't be created.
//

import AppKit
import CoreGraphics

// Shared state for the CGEvent callback (runs outside MainActor).
enum HotkeyState {
    nonisolated(unsafe) static var lastControlDownTime: CFAbsoluteTime = 0
    nonisolated(unsafe) static var controlWasDown: Bool = false
    nonisolated(unsafe) static var shouldToggle: Bool = false
    nonisolated(unsafe) static var configuredInterval: TimeInterval = 0.4
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    weak var engine: MacDictationEngine?

    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var hasAccessibilityPermission: Bool = false
    @Published var statusMessage: String = ""

    var doubleTapInterval: TimeInterval = 0.4

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?

    // NSEvent fallback monitors
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // For NSEvent-based double-tap detection
    private var nsLastControlDown: Date?
    private var nsControlIsDown: Bool = false

    init() {}

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        pollTimer?.invalidate()
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    func setup() {
        checkAccessibilityPermission()
        register()
    }

    func register() {
        unregister()
        HotkeyState.configuredInterval = doubleTapInterval

        // Try CGEventTap first — most reliable for global monitoring.
        if tryRegisterCGEventTap() {
            statusMessage = "Hotkey: Control×2 (CGEventTap)"
            isRegistered = true
            return
        }

        // Fallback: NSEvent monitors.
        registerNSEventMonitors()
        statusMessage = "Hotkey: Control×2 (NSEvent fallback)"
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

    // MARK: - CGEventTap approach

    private func tryRegisterCGEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: globalHotkeyCallback,
            userInfo: nil
        ) else {
            statusMessage = "CGEventTap failed — using NSEvent fallback"
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Poll for toggle requests from the C callback.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if HotkeyState.shouldToggle {
                    HotkeyState.shouldToggle = false
                    self?.engine?.toggle()
                }
            }
        }

        return true
    }

    // MARK: - NSEvent fallback

    private func registerNSEventMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleNSFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleNSFlags(event)
            }
            return event
        }
    }

    private func handleNSFlags(_ event: NSEvent) {
        let controlNow = event.modifierFlags.contains(.control)
        let others: NSEvent.ModifierFlags = [.command, .option, .shift]
        let hasOthers = !event.modifierFlags.intersection(others).isEmpty

        if controlNow && !nsControlIsDown && !hasOthers {
            nsControlIsDown = true
            let now = Date()
            if let last = nsLastControlDown,
               now.timeIntervalSince(last) <= doubleTapInterval {
                nsLastControlDown = nil
                engine?.toggle()
            } else {
                nsLastControlDown = now
            }
        } else if !controlNow && nsControlIsDown {
            nsControlIsDown = false
        }
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        hasAccessibilityPermission = trusted
    }
}

// C callback for CGEventTap.
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

        if (now - last) <= HotkeyState.configuredInterval && last > 0 {
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
