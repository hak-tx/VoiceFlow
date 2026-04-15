//
//  KeyboardViewController.swift
//  VoiceFlowKeyboard
//
//  Powered by KeyboardKit. Provides Apple-quality typing experience
//  (autocorrect, smart touch targets, native key sizing) plus our
//  custom action bar above the keyboard:
//    [Dictate in App] [AI Clean Up] [Undo?]
//

import UIKit
import SwiftUI
import KeyboardKit

class KeyboardViewController: KeyboardInputViewController {

    private var engine: VoiceFlowKeyboardEngine!

    override func viewDidLoad() {
        super.viewDidLoad()
        wireEngine()
    }

    /// Configure the keyboard view using KeyboardKit's SystemKeyboard
    /// with our custom toolbar above it.
    override func viewWillSetupKeyboardView() {
        super.viewWillSetupKeyboardView()

        setupKeyboardView { [weak self] controller in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                VStack(spacing: 0) {
                    // Our custom action bar above the keyboard.
                    VoiceFlowActionBar(engine: self.engine)

                    // KeyboardKit's standard QWERTY with autocorrect.
                    SystemKeyboard(
                        state: controller.state,
                        services: controller.services,
                        buttonContent: { $0.view },
                        buttonView: { $0.view },
                        emojiKeyboard: { $0.view },
                        toolbar: { _ in EmptyView() }
                    )
                }
            )
        }
    }

    // MARK: - Engine wiring

    private func wireEngine() {
        engine = VoiceFlowKeyboardEngine()

        engine.onInsertText = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
        engine.onDeleteBackward = { [weak self] in
            self?.textDocumentProxy.deleteBackward()
        }
        engine.onRequestKeyboardSwitch = { [weak self] in
            self?.advanceToNextInputMode()
        }
        engine.onReadAllText = { [weak self] in
            self?.readFullDocumentText() ?? ""
        }
        engine.onReplaceAllText = { [weak self] newText in
            self?.replaceFullDocumentText(with: newText)
        }
        engine.onOpenMainAppForDictation = { [weak self] in
            self?.openMainApp()
        }
    }

    // MARK: - Open main app

    private func openMainApp() {
        let url = URL(string: "voiceflow://dictate")!

        // Approach 1: extensionContext.open() — documented API.
        extensionContext?.open(url) { [weak self] success in
            if success { return }
            // Approach 2: responder chain fallback.
            DispatchQueue.main.async {
                self?.openURLViaResponderChain(url)
            }
        }
    }

    private func openURLViaResponderChain(_ url: URL) {
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

    // MARK: - Read / Replace document text

    private func readFullDocumentText() -> String {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        return before + after
    }

    private func replaceFullDocumentText(with newText: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""

        if !after.isEmpty {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: after.count)
        }

        let total = before.count + after.count
        for _ in 0..<total {
            textDocumentProxy.deleteBackward()
        }

        textDocumentProxy.insertText(newText)
    }
}

// MARK: - Custom action bar above keyboard

private struct VoiceFlowActionBar: View {
    @ObservedObject var engine: VoiceFlowKeyboardEngine

    var body: some View {
        HStack(spacing: 8) {
            // Dictate in App
            Button {
                engine.onOpenMainAppForDictation?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Dictate in App")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            // AI Clean Up
            Button {
                engine.runManualAICleanup()
            } label: {
                HStack(spacing: 6) {
                    if engine.isCleaning {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Text(engine.isCleaning ? "Cleaning..." : "AI Clean Up")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color.purple)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(engine.isCleaning)

            // Undo (conditional)
            if engine.canUndo {
                Button {
                    engine.undoLastCleanup()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 34)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}
