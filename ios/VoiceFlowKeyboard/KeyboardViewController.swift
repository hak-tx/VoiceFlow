//
//  KeyboardViewController.swift
//  VoiceFlowKeyboard
//
//  Custom keyboard extension. When the user is typing in a text
//  field anywhere in iOS and switches to the VoiceFlow keyboard,
//  this view controller is what gets shown.
//
//  Flow:
//    1. User taps the big mic button -> recording starts via
//       VoiceFlowKeyboardEngine (which wraps SFSpeechRecognizer).
//    2. Silence auto-stop (or user taps Done) fires cleanup.
//    3. Cleanup hits Claude via ClaudeCleanup (shared with main app).
//    4. Polished text is inserted into the host app's text field via
//       `textDocumentProxy.insertText(_:)`.
//
//  Keyboard extensions require "Full Access" from the user before
//  they can make network requests. The onboarding in the main app
//  walks users through enabling it; without Full Access, the polish
//  step fails and we insert the raw transcript as a fallback.
//

import UIKit
import SwiftUI

class KeyboardViewController: UIInputViewController {

    private var engine: VoiceFlowKeyboardEngine!
    private var hostingController: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        engine = VoiceFlowKeyboardEngine()
        engine.onInsertText = { [weak self] text in
            guard let self else { return }
            self.textDocumentProxy.insertText(text)
        }
        engine.onRequestKeyboardSwitch = { [weak self] in
            self?.advanceToNextInputMode()
        }

        // `hasFullAccess` is a built-in property on
        // UIInputViewController — true only when the user has
        // toggled Allow Full Access in Settings → Keyboards. Without
        // it, network calls (including the Claude API) are blocked.
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
