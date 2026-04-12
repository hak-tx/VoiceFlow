//
//  GlobalHotkeyManager.swift
//  VoiceFlowMac
//
//  Detects the "double Control" (^^) hotkey system-wide using a
//  CGEvent tap. When the user presses the Control key twice within
//  a short window (~400ms), the manager fires `onHotkeyActivated`.
//
//  A second double-Control deactivates (toggle behavior).
//
//  Requires Accessibility permission (System Settings → Privacy &
//  Security → Accessibility → VoiceFlowMac). Without it, the
//  CGEvent tap cannot be created and the hotkey won't work.
//

import Cocoa
import Combine
import Carbon.HIToolbox
import os.log

private let log = Logger(subsystem: "com.hak-tx.voiceflow.mac", category: "Hotkey")

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    // MARK: - Published state

    /// True when dictation is active (toggled by double-Control).
    @Published private(set) var isActive: Bool = false

    /// True if the app has Accessibility permission to install the
    /// event tap. False means the hotkey can't work.
    @Published private(set) var hasAccessibilityPermission: Bool = false

    /// Fires when the hotkey toggles dictation on.
    var onActivate: (() -> Void)?

    /// Fires when the hotkey toggles dictation off.
    var onDeactivate: (() -> Void)?

    // MARK: - Singleton for AppDelegate teardown

    static weak var shared: GlobalHotkeyManager?

    // MARK: - Private state

    /// The CGEvent tap that intercepts flagsChanged events.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Timestamp of the last Control key-down. Used to detect double-
    /// tap within the threshold.
    private nonisolated(unsafe) static var lastControlDownTime: TimeInterval = 0

    /// Threshold: two Control presses must be within this window.
    private static let doubleTapThreshold: TimeInterval = 0.4

    /// Debounce: ignore rapid re-fires after a successful double-tap.
    private nonisolated(unsafe) static var lastFireTime: TimeInterval = 0
    private static let debounceInterval: TimeInterval = 0.5

    /// Weak reference for the C callback to call back into Swift.
    private nonisolated(unsafe) static var instance: GlobalHotkeyManager?

    /// Timer that periodically re-checks Accessibility permission so
    /// the UI updates when the user grants access in System Settings
    /// (there's no system callback for this — polling is the standard
    /// approach used by Alfred, Raycast, etc.).
    private var permissionPollTimer: Timer?

    // MARK: - Init

    init() {
        Self.shared = self
        Self.instance = self
        checkAccessibilityPermission()
        startPermissionPolling()
    }

    // MARK: - Public API

    /// Install the global event tap. Call once on app launch after
    /// wiring onActivate/onDeactivate.
    func install() {
        guard eventTap == nil else {
            log.info("Event tap already installed")
            return
        }

        log.info("Attempting to install CGEvent tap...")
        log.info("AXIsProcessTrusted: \(AXIsProcessTrusted())")

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // The CGEvent callback must be a plain C function pointer — it
        // can't capture `self`. We use a static weak reference instead.
        let callback: CGEventTapCallBack = { _, _, event, _ in
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Control keys: left=0x3B (59), right=0x3E (62)
            let isControlKey = keyCode == 0x3B || keyCode == 0x3E

            // Check if Control is the ONLY modifier pressed (no Cmd, Option, Shift)
            let controlOnly = flags.contains(.maskControl)
                && !flags.contains(.maskCommand)
                && !flags.contains(.maskAlternate)
                && !flags.contains(.maskShift)

            // Key-down: Control flag is present and it's a Control key
            let isKeyDown = controlOnly && isControlKey

            if isKeyDown {
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - GlobalHotkeyManager.lastControlDownTime
                GlobalHotkeyManager.lastControlDownTime = now

                if elapsed < GlobalHotkeyManager.doubleTapThreshold
                    && elapsed > 0.05  // ignore hardware repeat
                    && (now - GlobalHotkeyManager.lastFireTime) > GlobalHotkeyManager.debounceInterval {
                    GlobalHotkeyManager.lastFireTime = now
                    DispatchQueue.main.async {
                        GlobalHotkeyManager.instance?.toggle()
                    }
                }
            }

            return Unmanaged.passRetained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            hasAccessibilityPermission = false
            log.error("CGEvent.tapCreate FAILED — Accessibility permission not granted or sandbox blocking")
            return
        }

        hasAccessibilityPermission = true
        eventTap = tap
        log.info("CGEvent tap installed successfully — ⌃⌃ hotkey active")

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Remove the event tap and clean up.
    func teardown() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        Self.instance = nil
    }

    /// Check whether Accessibility permission has been granted.
    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        )
        hasAccessibilityPermission = trusted
    }

    /// Prompt the user for Accessibility permission. Opens the
    /// System Settings → Privacy & Security → Accessibility pane
    /// with VoiceFlow highlighted. Permission persists permanently
    /// once granted (survives reboots, app updates via the same
    /// bundle ID). The polling timer detects when it's granted.
    func requestAccessibilityPermission() {
        let _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        )
    }

    /// Poll every 2 seconds to detect when Accessibility permission
    /// is granted. macOS has no callback/notification for this — every
    /// real productivity app (Alfred, Raycast, Bartender) polls.
    /// When permission flips from false→true, auto-install the event
    /// tap so the user doesn't need to restart.
    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasTrusted = self.hasAccessibilityPermission
                self.checkAccessibilityPermission()
                // Auto-install the event tap when permission is newly granted.
                if !wasTrusted && self.hasAccessibilityPermission {
                    self.install()
                }
            }
        }
    }

    // MARK: - Toggle

    private func toggle() {
        isActive.toggle()
        if isActive {
            onActivate?()
        } else {
            onDeactivate?()
        }
    }

    /// Force deactivate (e.g., after polish completes).
    func deactivate() {
        guard isActive else { return }
        isActive = false
    }
}
