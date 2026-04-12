//
//  GlobalHotkey.swift
//  VoiceFlowMac
//
//  Global hotkey: Cmd+Shift+V to toggle dictation.
//
//  Uses Carbon's RegisterEventHotKey — the most reliable global
//  hotkey API on macOS. Does NOT require Accessibility permissions.
//  Works from any app, any context.
//

import AppKit
import Carbon

@MainActor
final class GlobalHotkeyManager: ObservableObject {

    weak var engine: MacDictationEngine?

    @Published private(set) var isRegistered: Bool = false

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    // Store the singleton so the C callback can reach it.
    private static weak var shared: GlobalHotkeyManager?

    init() {}

    deinit {
        unregister()
    }

    func setup() {
        GlobalHotkeyManager.shared = self
        register()
    }

    func register() {
        unregister()

        // Cmd+Shift+V → keyCode 9 is 'V' on US keyboard
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x5646_4C57),  // "VFLW"
            id: 1
        )

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Install a Carbon event handler for hotkey events.
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                // C callback — bridge to the singleton.
                Task { @MainActor in
                    GlobalHotkeyManager.shared?.engine?.toggle()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        guard status == noErr else {
            isRegistered = false
            return
        }

        // Register Cmd+Shift+V (keyCode 9 = V).
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = 9  // V

        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        isRegistered = (regStatus == noErr)
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        isRegistered = false
    }
}
