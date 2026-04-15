//
//  KeyboardRootView.swift
//  VoiceFlowKeyboard
//
//  SwiftUI root view hosted inside UIInputViewController. Provides
//  two modes:
//
//    1. TYPING MODE  - Full QWERTY layout with shift, backspace,
//       return, space, 123/symbols toggle, globe, and mic button.
//    2. DICTATION MODE - Big mic button, tone picker, live transcript,
//       keyboard-return button, globe button.
//
//  The keyboard extension has ~260pt default height. Key sizing and
//  spacing are tuned to feel native to iOS.
//

import SwiftUI

// MARK: - Keyboard Mode

private enum KeyboardMode {
    case typing
    case dictation
}

// MARK: - Typing sub-mode (letters vs numbers/symbols)

private enum TypingPage {
    case letters
    case numbers
    case symbols
}

// MARK: - Shift state

private enum ShiftState {
    case lower
    case upper      // single-tap shift
    case capsLock   // double-tap shift
}

// MARK: - Root View

struct KeyboardRootView: View {
    @ObservedObject var engine: VoiceFlowKeyboardEngine
    let hasFullAccess: Bool

    @State private var mode: KeyboardMode = .typing
    @State private var typingPage: TypingPage = .letters
    @State private var shiftState: ShiftState = .lower
    @State private var lastShiftTapTime: Date = .distantPast

    var body: some View {
        if !hasFullAccess {
            fullAccessExplainer
        } else {
            Group {
                switch mode {
                case .typing:
                    typingModeView
                case .dictation:
                    dictationModeView
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemGray6))
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - TYPING MODE
    // ──────────────────────────────────────────────

    private var typingModeView: some View {
        VStack(spacing: 0) {
            // Action bar above keyboard: Dictate + AI Clean Up + Undo
            voiceDictateBar

            switch typingPage {
            case .letters:
                lettersLayout
            case .numbers:
                numbersLayout
            case .symbols:
                symbolsLayout
            }
            bottomRow
        }
        .padding(.horizontal, 3)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    // MARK: Voice dictate bar (prominent, above keyboard)

    private var voiceDictateBar: some View {
        HStack(spacing: 8) {
            // Open main app for dictation (left, accent color).
            Button {
                engine.onOpenMainAppForDictation?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text("Dictate in App")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            // AI Clean Up button (right, purple/sparkles).
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
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(engine.isCleaning ? "Cleaning..." : "AI Clean Up")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color.purple)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(engine.isCleaning)

            // Undo (only visible when cleanup history exists).
            if engine.canUndo {
                Button {
                    engine.undoLastCleanup()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 36)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    // MARK: Letters layout

    private var lettersLayout: some View {
        let row1 = ["q","w","e","r","t","y","u","i","o","p"]
        let row2 = ["a","s","d","f","g","h","j","k","l"]
        let row3 = ["z","x","c","v","b","n","m"]

        return VStack(spacing: 8) {
            // Row 1
            HStack(spacing: 4) {
                ForEach(row1, id: \.self) { key in
                    characterKey(displayedAs(key))
                }
            }
            // Row 2 (slightly inset)
            HStack(spacing: 4) {
                ForEach(row2, id: \.self) { key in
                    characterKey(displayedAs(key))
                }
            }
            // Row 3: shift + letters + backspace
            HStack(spacing: 4) {
                shiftKey
                ForEach(row3, id: \.self) { key in
                    characterKey(displayedAs(key))
                }
                backspaceKey
            }
        }
    }

    // MARK: Numbers layout

    private var numbersLayout: some View {
        let row1 = ["1","2","3","4","5","6","7","8","9","0"]
        let row2 = ["-","/",":",";","(",")","$","&","@","\""]
        let row3 = [".",",","?","!","'"]

        return VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(row1, id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: 4) {
                ForEach(row2, id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: 4) {
                symbolsToggleKey
                ForEach(row3, id: \.self) { key in
                    characterKey(key)
                }
                backspaceKey
            }
        }
    }

    // MARK: Symbols layout

    private var symbolsLayout: some View {
        let row1 = ["[","]","{","}","#","%","^","*","+","="]
        let row2 = ["_","\\","|","~","<",">","\u{20AC}","\u{00A3}","\u{00A5}","\u{2022}"]
        let row3 = [".",",","?","!","'"]

        return VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(row1, id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: 4) {
                ForEach(row2, id: \.self) { key in
                    characterKey(key)
                }
            }
            HStack(spacing: 4) {
                numbersToggleKey
                ForEach(row3, id: \.self) { key in
                    characterKey(key)
                }
                backspaceKey
            }
        }
    }

    // MARK: Bottom row (shared across all typing pages)

    private var bottomRow: some View {
        HStack(spacing: 4) {
            // Globe
            actionKey(systemImage: "globe", width: 42) {
                engine.requestKeyboardSwitch()
            }

            // 123 / ABC toggle
            if typingPage == .letters {
                actionKey(label: "123", width: 42) {
                    typingPage = .numbers
                }
            } else {
                actionKey(label: "ABC", width: 42) {
                    typingPage = .letters
                    shiftState = .lower
                }
            }

            // Space bar
            Button {
                engine.keyTyped(" ")
            } label: {
                Text("space")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(.systemGray5))
                    )
            }

            // Return
            actionKey(label: "return", width: 72, color: Color(.systemGray3)) {
                engine.keyTyped("\n")
            }

            // (mic moved to prominent bar above the keyboard)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // ──────────────────────────────────────────────
    // MARK: - Key builders
    // ──────────────────────────────────────────────

    /// Standard character key — inserts the character on tap.
    private func characterKey(_ char: String) -> some View {
        Button {
            engine.keyTyped(char)
            // Auto-lower after a single uppercase letter (not caps lock)
            if shiftState == .upper {
                shiftState = .lower
            }
        } label: {
            Text(char)
                .font(.system(size: 22))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(.systemGray5))
                )
        }
    }

    /// Shift key with three-state cycling.
    private var shiftKey: some View {
        Button {
            let now = Date()
            let interval = now.timeIntervalSince(lastShiftTapTime)
            lastShiftTapTime = now

            switch shiftState {
            case .lower:
                shiftState = .upper
            case .upper:
                // Double-tap to caps lock (within 0.4s)
                if interval < 0.4 {
                    shiftState = .capsLock
                } else {
                    shiftState = .lower
                }
            case .capsLock:
                shiftState = .lower
            }
        } label: {
            Image(systemName: shiftIconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(shiftState != .lower ? Color(.systemGray4) : Color(.systemGray3))
                )
        }
    }

    private var shiftIconName: String {
        switch shiftState {
        case .lower: return "shift"
        case .upper: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
    }

    /// Backspace key.
    private var backspaceKey: some View {
        Button {
            engine.onDeleteBackward?()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(.systemGray3))
                )
        }
    }

    /// "#+=": switch from numbers to symbols page.
    private var symbolsToggleKey: some View {
        actionKey(label: "#+=", width: 42) {
            typingPage = .symbols
        }
    }

    /// "123": switch from symbols back to numbers page.
    private var numbersToggleKey: some View {
        actionKey(label: "123", width: 42) {
            typingPage = .numbers
        }
    }

    /// Generic action key with text label.
    private func actionKey(
        label: String,
        width: CGFloat,
        color: Color = Color(.systemGray3),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: width, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color)
                )
        }
    }

    /// Generic action key with SF Symbol.
    private func actionKey(
        systemImage: String,
        width: CGFloat,
        color: Color = Color(.systemGray3),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: width, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color)
                )
        }
    }

    /// Transforms a letter based on shift state.
    private func displayedAs(_ key: String) -> String {
        switch shiftState {
        case .lower:
            return key.lowercased()
        case .upper, .capsLock:
            return key.uppercased()
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - DICTATION MODE
    // ──────────────────────────────────────────────

    private var dictationModeView: some View {
        VStack(spacing: 8) {
            dictationTopBar
            Spacer(minLength: 4)
            dictationMicButton
            dictationTranscriptLine
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var dictationTopBar: some View {
        HStack {
            // Tone picker
            Menu {
                ForEach(TonePreset.allCases) { preset in
                    Button {
                        engine.tonePreset = preset
                    } label: {
                        HStack {
                            Image(systemName: preset.symbolName)
                            Text(preset.title)
                            if engine.tonePreset == preset {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: engine.tonePreset.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(engine.tonePreset.title)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                )
            }

            Spacer()

            // Keyboard icon (switch back to typing)
            Button {
                mode = .typing
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemBackground))
                    )
            }

            // Globe key
            Button {
                engine.requestKeyboardSwitch()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
        }
    }

    private var dictationMicButton: some View {
        Button {
            engine.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(engine.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 88, height: 88)
                    .shadow(radius: engine.isRecording ? 6 : 3)

                if engine.isPolishing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                } else {
                    Image(systemName: engine.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .scaleEffect(engine.isRecording ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: engine.isRecording)
    }

    private var dictationTranscriptLine: some View {
        Text(dictationStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 8)
    }

    private var dictationStatus: String {
        if engine.isPolishing { return "Cleaning up\u{2026}" }
        if engine.isRecording {
            return engine.liveTranscript.isEmpty ? "Listening\u{2026}" : engine.liveTranscript
        }
        if let err = engine.errorMessage {
            return err
        }
        return "Tap mic to dictate"
    }

    // ──────────────────────────────────────────────
    // MARK: - Full Access explainer
    // ──────────────────────────────────────────────

    private var fullAccessExplainer: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
            Text("Enable Full Access")
                .font(.subheadline.weight(.semibold))
            Text("VoiceFlow needs Full Access to send your speech to Claude for cleanup. Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards \u{2192} VoiceFlow \u{2192} Allow Full Access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .background(Color(.systemGray6))
    }
}
