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
//  Requires Accessibility permission (System Settings → Privacy &
//  Security → Accessibility).
//

import Cocoa
import ApplicationServices
import os.log

private let log = Logger(subsystem: "com.hak-tx.voiceflow.mac", category: "Accessibility")

@MainActor
final class AccessibilityTextManager: ObservableObject {

    // MARK: - Published state

    /// The text currently selected in the focused app.
    @Published private(set) var selectedText: String = ""

    /// Full value of the focused text field (if readable). Capped at
    /// 50,000 characters to prevent memory spikes on huge documents.
    @Published private(set) var fullText: String = ""

    /// The character range of the current selection within fullText.
    @Published private(set) var selectedRange: CFRange = CFRange(location: 0, length: 0)

    /// Screen-space rect of the current selection or cursor. Used to
    /// position the overlay panel near where the user is typing.
    @Published private(set) var cursorRect: CGRect = .zero

    /// Last error encountered during AX operations. Surfaced in the UI
    /// so the user knows when something isn't working.
    @Published private(set) var lastError: String?

    private static let maxTextCapture = 50_000

    // MARK: - Public API

    /// Snapshot the focused element's text, selection, and cursor
    /// position. Call this right before starting dictation so we
    /// know what to replace and where to show the overlay.
    func captureCurrentContext() {
        lastError = nil

        guard let focused = focusedTextElement() else {
            log.info("No focused text element found — cursor may not be in a text field")
            clearState()
            return
        }

        // Read the full text value.
        if let value = stringAttribute(.value, of: focused) {
            if value.count > Self.maxTextCapture {
                fullText = String(value.prefix(Self.maxTextCapture))
                log.info("Text field value truncated from \(value.count) to \(Self.maxTextCapture) chars")
            } else {
                fullText = value
            }
        } else {
            fullText = ""
        }

        // Read the selected text range.
        if let range = rangeAttribute(.selectedTextRange, of: focused) {
            selectedRange = range

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
        log.debug("Captured context: \(self.fullText.count) chars, selection \(self.selectedRange.length) chars")
    }

    /// Insert text at the current cursor position, replacing any
    /// selection. This is the primary "output" path — after cleanup,
    /// the polished text gets typed into whatever app the user was in.
    func insertText(_ text: String) {
        lastError = nil

        guard let focused = focusedTextElement() else {
            log.info("No focused text element for insert — falling back to Cmd-V paste")
            pasteViaClipboard(text)
            return
        }

        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if result != .success {
            log.warning("AX text insertion failed (error \(result.rawValue)) — falling back to Cmd-V paste")
            pasteViaClipboard(text)
        } else {
            log.info("Inserted \(text.count) chars via AX API")
        }
    }

    /// Replace a specific range in the focused text field with new text.
    func replaceRange(_ range: CFRange, with text: String) {
        lastError = nil

        guard let focused = focusedTextElement() else {
            log.info("No focused text element for replaceRange — falling back to Cmd-V paste")
            pasteViaClipboard(text)
            return
        }

        // Set the selection to the target range first.
        var mutableRange = range
        if let rangeValue = AXValueCreate(.cfRange, &mutableRange) {
            let setResult = AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
            if setResult != .success {
                log.warning("Failed to set selection range (error \(setResult.rawValue))")
            }
        }

        // Now replace the selection with the new text.
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if result != .success {
            log.warning("AX range replacement failed (error \(result.rawValue)) — falling back to Cmd-V paste")
            pasteViaClipboard(text)
        }
    }

    // MARK: - Direct methods (no clipboard fallback)
    // Used during live streaming to prevent duplication.

    /// Insert text at cursor. Returns false if AX isn't available.
    /// Does NOT fall back to clipboard paste.
    @discardableResult
    func insertTextDirect(_ text: String) -> Bool {
        guard let focused = focusedTextElement() else {
            log.info("insertTextDirect: no focused element")
            return false
        }
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    /// Replace a range with new text. Returns false if AX isn't available.
    /// Does NOT fall back to clipboard paste.
    @discardableResult
    func replaceRangeDirect(_ range: CFRange, with text: String) -> Bool {
        guard let focused = focusedTextElement() else {
            log.info("replaceRangeDirect: no focused element")
            return false
        }
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return false
        }
        let selectResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        guard selectResult == .success else {
            log.warning("replaceRangeDirect: failed to set selection (error \(selectResult.rawValue))")
            return false
        }
        let replaceResult = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return replaceResult == .success
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
        guard appResult == .success else {
            if appResult == .apiDisabled {
                lastError = "Accessibility permission not granted. Open System Settings → Privacy & Security → Accessibility."
            }
            return nil
        }

        // Safe cast — AXUIElementCopyAttributeValue returns CFTypeRef.
        guard CFGetTypeID(focusedApp) == AXUIElementGetTypeID() else {
            log.error("Focused app attribute is not an AXUIElement")
            return nil
        }
        let app = focusedApp as! AXUIElement

        var focusedElement: AnyObject?
        let elemResult = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard elemResult == .success else {
            return nil
        }

        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            log.error("Focused element is not an AXUIElement")
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    /// Read a string attribute from an AX element. Returns nil on any
    /// error instead of force-casting.
    private func stringAttribute(_ attr: NSAccessibility.Attribute, of element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            attr.rawValue as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value as? String
    }

    /// Read a CFRange attribute from an AX element. Returns nil on any
    /// error instead of force-casting.
    private func rangeAttribute(_ attr: NSAccessibility.Attribute, of element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            attr.rawValue as CFString,
            &value
        )
        guard result == .success else { return nil }

        // AXValue wraps a CFRange. Verify the type before extracting.
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue

        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Read a raw AXValue attribute (for parameterized queries).
    private func rawAttribute(_ attr: NSAccessibility.Attribute, of element: AXUIElement) -> AnyObject? {
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
        // Try to get bounds of selected text range.
        if let rangeValue = rawAttribute(.selectedTextRange, of: element) {
            var boundsValue: AnyObject?
            let result = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue as CFTypeRef,
                &boundsValue
            )
            if result == .success,
               let bv = boundsValue,
               CFGetTypeID(bv) == AXValueGetTypeID() {
                let axVal = bv as! AXValue
                if AXValueGetType(axVal) == .cgRect {
                    var bounds = CGRect.zero
                    if AXValueGetValue(axVal, .cgRect, &bounds) {
                        return bounds
                    }
                }
            }
        }

        // Fallback: use the element's overall position + size.
        return elementFrame(of: element)
    }

    /// Get an element's screen position + size as a rect.
    private func elementFrame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var gotPosition = false
        var gotSize = false

        if let posObj = rawAttribute(.position, of: element),
           CFGetTypeID(posObj) == AXValueGetTypeID() {
            let axVal = posObj as! AXValue
            if AXValueGetType(axVal) == .cgPoint {
                gotPosition = AXValueGetValue(axVal, .cgPoint, &position)
            }
        }
        if let sizeObj = rawAttribute(.size, of: element),
           CFGetTypeID(sizeObj) == AXValueGetTypeID() {
            let axVal = sizeObj as! AXValue
            if AXValueGetType(axVal) == .cgSize {
                gotSize = AXValueGetValue(axVal, .cgSize, &size)
            }
        }

        guard gotPosition || gotSize else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Fallback insertion: copy text to clipboard and simulate Cmd-V.
    /// Saves and restores the previous clipboard contents.
    private func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore the old clipboard after a delay.
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
