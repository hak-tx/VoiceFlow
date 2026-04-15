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

        // Open main VoiceFlow app for dictation via URL scheme.
        // extensionContext.open() doesn't work in keyboard extensions,
        // so we walk the responder chain to find UIApplication and
        // call openURL: directly.
        engine.onOpenMainAppForDictation = { [weak self] in
            guard let self,
                  let url = URL(string: "voiceflow://dictate") else { return }
            var responder: UIResponder? = self
            while let r = responder {
                if let app = r as? UIApplication {
                    app.perform(
                        NSSelectorFromString("openURL:"),
                        with: url
                    )
                    return
                }
                responder = r.next
            }
            // Fallback: try extensionContext (works in some iOS versions)
            self.extensionContext?.open(url, completionHandler: nil)
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
