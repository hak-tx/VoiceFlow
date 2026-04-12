//
//  AccessibilityTextManager.swift
//  VoiceFlowMac
//
//  Uses the macOS Accessibility API to interact with the focused
//  text field in any application. Capabilities:
//
//    1. Read the currently selected text (for replace-selection flow).
//    2. Read surrounding context (text before/after selection) so
//       Claude can match tone and punctuation.
//    3. Insert or replace text at the cursor position.
//    4. Get the screen-space position of the cursor/selection for
//       positioning the overlay panel.
//
//  Requires Accessibility permission (same as GlobalHotkeyManager).
//

import Cocoa
import ApplicationServices

@MainActor
final class AccessibilityTextManager: ObservableObject {

    // MARK: - Published state

    /// The text currently selected in the focused app. Empty if no
    /// selection or no accessible text field.
    @Published private(set) var selectedText: String = ""

    /// Full value of the focused text field (if readable).
    @Published private(set) var fullText: String = ""

    /// The character range of the current selection within fullText.
    @Published private(set) var selectedRange: CFRange = CFRange(location: 0, length: 0)

    /// Screen-space rect of the current selection or cursor. Used to
    /// position the overlay panel near where the user is typing.
    @Published private(set) var cursorRect: CGRect = .zero

    // MARK: - Public API

    /// Snapshot the focused element's text, selection, and cursor
    /// position. Call this right before starting dictation so we
    /// know what to replace and where to show the overlay.
    func captureCurrentContext() {
        guard let focused = focusedTextElement() else {
            clearState()
            return
        }

        // Read the full text value.
        if let value = attribute(.value, of: focused) as? String {
            fullText = value
        } else {
            fullText = ""
        }

        // Read the selected text range.
        if let rangeValue = attribute(.selectedTextRange, of: focused) {
            let axValue = rangeValue as! AXValue
            var range = CFRange(location: 0, length: 0)
            AXValueGetValue(axValue, .cfRange, &range)
            selectedRange = range

            // Extract the selected substring.
            if range.length > 0, range.location >= 0,
               range.location + range.length <= fullText.count {
                let start = fullText.index(fullText.startIndex, offsetBy: range.location)
                let end = fullText.index(start, offsetBy: range.length)
                selectedText = String(fullText[start..<end])
            } else {
                selectedText = ""
            }
        } else {
            selectedRange = CFRange(location: 0, length: 0)
            selectedText = ""
        }

        // Get the screen rect of the selection/cursor for overlay
        // positioning.
        cursorRect = selectionBounds(of: focused) ?? .zero
    }

    /// Insert text at the current cursor position, replacing any
    /// selection. This is the primary "output" path — after cleanup,
    /// the polished text gets typed into whatever app the user was in.
    func insertText(_ text: String) {
        guard let focused = focusedTextElement() else {
            // Fallback: use the pasteboard + Cmd-V.
            pasteViaClipboard(text)
            return
        }

        // If there's a selection, replace it. Otherwise insert at cursor.
        let success = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if success != .success {
            // Fallback: set the selected text range first, then value.
            pasteViaClipboard(text)
        }
    }

    /// Replace a specific range in the focused text field with new text.
    /// Used for the splice-after-redictate flow where we replace
    /// exactly the selected portion.
    func replaceRange(_ range: CFRange, with text: String) {
        guard let focused = focusedTextElement() else {
            pasteViaClipboard(text)
            return
        }

        // Set the selection to the target range first.
        var mutableRange = range
        if let rangeValue = AXValueCreate(.cfRange, &mutableRange) {
            AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        // Now replace the selection with the new text.
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if result != .success {
            pasteViaClipboard(text)
        }
    }

    /// Get the text surrounding the current selection for splice context.
    /// Returns (textBefore, textAfter) — up to 200 chars on each side.
    func surroundingContext() -> (before: String, after: String) {
        guard !fullText.isEmpty else { return ("", "") }

        let loc = selectedRange.location
        let len = selectedRange.length
        guard loc >= 0, loc <= fullText.count else { return ("", "") }

        let beforeEnd = fullText.index(fullText.startIndex, offsetBy: min(loc, fullText.count))
        let beforeStart = fullText.index(beforeEnd, offsetBy: -min(200, loc), limitedBy: fullText.startIndex) ?? fullText.startIndex
        let before = String(fullText[beforeStart..<beforeEnd])

        let afterStart = fullText.index(fullText.startIndex, offsetBy: min(loc + len, fullText.count))
        let afterEnd = fullText.index(afterStart, offsetBy: min(200, fullText.count - min(loc + len, fullText.count)), limitedBy: fullText.endIndex) ?? fullText.endIndex
        let after = String(fullText[afterStart..<afterEnd])

        return (before, after)
    }

    // MARK: - Private helpers

    /// Get the focused AXUIElement that represents a text field.
    private func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        guard appResult == .success, let app = focusedApp else {
            return nil
        }

        var focusedElement: AnyObject?
        let elemResult = AXUIElementCopyAttributeValue(
            app as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard elemResult == .success, let element = focusedElement else {
            return nil
        }

        return (element as! AXUIElement)
    }

    /// Read a single AX attribute from an element.
    private func attribute(_ attr: NSAccessibility.Attribute, of element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            attr.rawValue as CFString,
            &value
        )
        return result == .success ? value : nil
    }

    /// Get the screen-space bounds of the current text selection or
    /// insertion point. Used to position the floating overlay.
    private func selectionBounds(of element: AXUIElement) -> CGRect? {
        // Try to get bounds of selected text first.
        if let rangeValue = attribute(.selectedTextRange, of: element) {
            var bounds = CGRect.zero
            var boundsValue: AnyObject?
            let result = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue as CFTypeRef,
                &boundsValue
            )
            if result == .success, let axValue = boundsValue {
                AXValueGetValue(axValue as! AXValue, .cgRect, &bounds)
                return bounds
            }
        }

        // Fallback: use the element's overall position + size.
        var position = CGPoint.zero
        var size = CGSize.zero

        if let posValue = attribute(.position, of: element) {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }
        if let sizeValue = attribute(.size, of: element) {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    /// Fallback insertion: copy text to clipboard and simulate Cmd-V.
    private func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd-V keypress.
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V key
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore the old clipboard after a short delay.
        if let old = oldContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }

    private func clearState() {
        selectedText = ""
        fullText = ""
        selectedRange = CFRange(location: 0, length: 0)
        cursorRect = .zero
    }
}
