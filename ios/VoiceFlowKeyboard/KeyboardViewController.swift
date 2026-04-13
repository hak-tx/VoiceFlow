//
//  KeyboardViewController.swift
//  VoiceFlowKeyboard
//
//  Custom keyboard extension. Provides two modes:
//
//    1. TYPING MODE  - Full QWERTY keyboard with shift, backspace,
//       numbers/symbols, globe, return, space, and a mic button to
//       switch to dictation mode.
//    2. DICTATION MODE - Mic-driven speech-to-text via
//       VoiceFlowKeyboardEngine, with tone picker, live transcript,
//       and a keyboard button to switch back to typing mode.
//
//  Text insertion and deletion both flow through the engine's
//  callbacks, which this controller wires to `textDocumentProxy`.
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
            guard let self else { return }
            self.textDocumentProxy.insertText(text)
        }

        // Delete backward in the host app's text field.
        engine.onDeleteBackward = { [weak self] in
            guard let self else { return }
            self.textDocumentProxy.deleteBackward()
        }

        // Switch to the next system keyboard (globe key).
        engine.onRequestKeyboardSwitch = { [weak self] in
            self?.advanceToNextInputMode()
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

    override func textWillChange(_ textInput: UITextInput?) {
        // Called before text changes in the host app.
    }

    override func textDidChange(_ textInput: UITextInput?) {
        // Called after text changes in the host app. Useful for
        // adapting UI based on keyboard appearance (light/dark).
    }
}
