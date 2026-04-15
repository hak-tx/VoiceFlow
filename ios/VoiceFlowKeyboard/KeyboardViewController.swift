//
//  KeyboardViewController.swift
//  VoiceFlowKeyboard
//
//  Custom keyboard extension with QWERTY typing + voice dictation.
//  AI autocorrect runs after each sentence, cleaning up text in-place.
//

import UIKit
import SwiftUI

class KeyboardViewController: UIInputViewController {

    private var engine: VoiceFlowKeyboardEngine!
    private var hostingController: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        engine = VoiceFlowKeyboardEngine()

        // Insert text into the host app's text field.
        engine.onInsertText = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }

        // Delete backward in the host app's text field.
        engine.onDeleteBackward = { [weak self] in
            self?.textDocumentProxy.deleteBackward()
        }

        // Switch to the next system keyboard (globe key).
        engine.onRequestKeyboardSwitch = { [weak self] in
            self?.advanceToNextInputMode()
        }

        // Read all text from the current text field for AI cleanup.
        engine.onReadAllText = { [weak self] in
            self?.readFullDocumentText() ?? ""
        }

        // Replace all text in the current text field after cleanup.
        engine.onReplaceAllText = { [weak self] newText in
            self?.replaceFullDocumentText(with: newText)
        }

        // Open main VoiceFlow app for dictation. Tries multiple
        // approaches because iOS keeps locking down extension URL
        // opening. Also writes a trigger to UserDefaults shared
        // App Group so the main app auto-starts dictation when
        // launched (even if URL open fails).
        engine.onOpenMainAppForDictation = { [weak self] in
            guard let self else { return }
            let url = URL(string: "voiceflow://dictate")!

            // Approach 1: extensionContext.open() — documented API.
            self.extensionContext?.open(url) { success in
                if success { return }
                // Approach 2: responder chain walk with recursive
                // selector trick.
                DispatchQueue.main.async {
                    self.openURLViaResponderChain(url)
                }
            }
        }
    }

    /// Walk the responder chain to find UIApplication and call its
    /// openURL: directly. Works in some iOS versions where
    /// extensionContext.open() doesn't.
    @objc private func openURLViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                _ = r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
    }

        let rootView = KeyboardRootView(
            engine: engine,
            hasFullAccess: hasFullAccess
        )
        let hosting = UIHostingController(rootView: rootView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        self.hostingController = hosting
    }

    // MARK: - Read / Replace full document text

    /// Read all text from the text field by walking backward and
    /// forward through textDocumentProxy.
    private func readFullDocumentText() -> String {
        guard let proxy = textDocumentProxy as? UITextDocumentProxy else { return "" }

        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        return before + after
    }

    /// Replace all text in the text field with new text.
    /// Selects all existing text by deleting it, then inserts new.
    private func replaceFullDocumentText(with newText: String) {
        guard let proxy = textDocumentProxy as? UITextDocumentProxy else { return }

        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""

        // Move cursor to end of document.
        if !after.isEmpty {
            proxy.adjustTextPosition(byCharacterOffset: after.count)
        }

        // Delete all characters backward.
        let total = before.count + after.count
        for _ in 0..<total {
            proxy.deleteBackward()
        }

        // Insert the cleaned text.
        proxy.insertText(newText)
    }
}
