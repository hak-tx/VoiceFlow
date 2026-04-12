//
//  DictationView.swift
//  VoiceFlow
//
//  Primary UI. Layout (no scrolling — everything fits in the viewport
//  on a standard phone):
//
//    ┌────────────────────────────────┐
//    │ ⚙  VoiceFlow PRO • build N  📚 🕑│  ← nav bar
//    ├────────────────────────────────┤
//    │ TONE  [Verbatim][Email][...]   │  ← compact tone row
//    ├────────────────────────────────┤
//    │                                │
//    │  editable transcript area      │  ← SelectableTextView
//    │  (SelectableTextView wraps     │    exposes NSRange selection
//    │   UITextView so we can read    │
//    │   selectedRange and do the     │
//    │   highlight-to-redictate flow) │
//    │                                │
//    ├────────────────────────────────┤
//    │ [Sel][Copy][Clear][Undo]       │  ← fixed 6-col action bar
//    │ [Redo][Share][Re-dictate…]     │    (no horizontal scroll)
//    ├────────────────────────────────┤
//    │            🎤                  │  ← mic control
//    └────────────────────────────────┘
//
//  Shows a transient confirmation pill when a voice command fires.
//

import SwiftUI
import UIKit

struct DictationView: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var vocabManager: VocabPackManager
    @EnvironmentObject var entitlements: EntitlementManager
    @EnvironmentObject var history: DictationHistoryStore
    @EnvironmentObject var pasteTargets: PasteTargetsManager
    @EnvironmentObject var settings: AppSettings

    @State private var showingPacks = false
    @State private var showingSettings = false
    @State private var showingPaywall = false
    @State private var showingShareSheet = false
    @State private var showingQuickDictate = false
    @State private var showingRecent = false
    @State private var paywallReason: PaywallReason = .manual

    /// Current selection inside the transcript view. Updated by
    /// SelectableTextView as the user drags / long-presses. Used by
    /// the "Re-dictate selection" action bar button.
    @State private var selectedRange: NSRange = NSRange(location: 0, length: 0)

    /// True when the transcript text view is currently focused (the
    /// iOS keyboard is up for manual edits). Bound to @FocusState in
    /// SelectableTextView via a callback so our nav-bar Done button
    /// is consistent.
    @FocusState private var transcriptFocused: Bool

    /// Dismiss the iOS keyboard if the TextEditor (or any other
    /// input) currently has focus. Called on every tap that isn't
    /// in the transcript itself so the keyboard doesn't linger over
    /// the tone / vocab / action UI.
    private func dismissKeyboard() {
        transcriptFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    /// Navigation bar title with the live CFBundleVersion baked in.
    /// Lets us tell at a glance which build is actually installed on
    /// the phone vs what TestFlight claims. Also shows "PRO" to verify
    /// the force-Pro hack is compiled into the current build.
    private static var navTitleWithBuild: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "VoiceFlow PRO • build \(build)"
    }

    private var visibleTranscript: String {
        if !engine.polishedTranscript.isEmpty {
            return engine.polishedTranscript
        }
        return engine.liveTranscript
    }

    private var isShowingPolished: Bool {
        !engine.polishedTranscript.isEmpty
    }

    /// True if there's a non-empty selection the user could ask to
    /// re-dictate. Enables the "Re-dictate" action bar button.
    private var hasSelection: Bool {
        selectedRange.length > 0 && !visibleTranscript.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toneRow
                transcriptArea
                Divider()
                actionBar
                Divider().opacity(0.5)
                controlBar
            }
            .overlay(alignment: .top) { commandConfirmationPill }
            // If the keyboard is up and the user taps anywhere in the
            // transcript-adjacent chrome, drop focus. Background tap
            // is a backup for the Done toolbar button.
            .contentShape(Rectangle())
            .navigationTitle(Self.navTitleWithBuild)
            .navigationBarTitleDisplayMode(.inline)
            // Pin the nav bar background opaque so scrolled / keyboard-
            // pushed content never bleeds up into the nav title area
            // (that's what caused the "Quick Dictate overlaps build
            // number" glitch on build 14).
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissKeyboard()
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismissKeyboard()
                        showingPacks = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "books.vertical")
                            if !vocabManager.activePackNames.isEmpty {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 3, y: -3)
                            }
                        }
                    }
                    .accessibilityLabel("Vocab packs")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismissKeyboard()
                        showingRecent = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Recent dictations")
                }
                // Keyboard-accessory Done button so the user can always
                // dismiss the keyboard from inside the transcript.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                        .font(.headline)
                }
            }
            .sheet(isPresented: $showingPacks) {
                VocabPackPickerView()
                    .environmentObject(vocabManager)
                    .environmentObject(entitlements)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(engine)
                    .environmentObject(vocabManager)
                    .environmentObject(entitlements)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(reason: paywallReason)
                    .environmentObject(entitlements)
            }
            .sheet(isPresented: $showingShareSheet) {
                if !visibleTranscript.isEmpty {
                    ShareSheet(items: [visibleTranscript])
                }
            }
            .fullScreenCover(isPresented: $showingQuickDictate) {
                QuickDictateView()
                    .environmentObject(engine)
                    .environmentObject(vocabManager)
                    .environmentObject(history)
                    .environmentObject(pasteTargets)
                    .environmentObject(settings)
            }
            .sheet(isPresented: $showingRecent) {
                RecentDictationsView()
                    .environmentObject(history)
                    .environmentObject(entitlements)
            }
            .alert(
                "Dictation error",
                isPresented: Binding(
                    get: { engine.errorMessage != nil },
                    set: { if !$0 { engine.errorMessage = nil } }
                ),
                presenting: engine.errorMessage
            ) { _ in
                Button("OK", role: .cancel) { engine.errorMessage = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    // MARK: - Tone preset row

    /// Compact horizontal row of tone chips. No big subtitle — just
    /// "TONE" label + chips — because screen real estate is at a
    /// premium and the subtitle was pushing the transcript down.
    private var toneRow: some View {
        HStack(spacing: 8) {
            Text("TONE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TonePreset.allCases) { preset in
                        toneChip(preset)
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func toneChip(_ preset: TonePreset) -> some View {
        let isActive = engine.tonePreset == preset
        // HACK: hard-coded false for internal testing so nothing is
        // Pro-gated in the UI. Revert to
        //   let isGated = preset.requiresPro && !entitlements.hasPro
        // before public release.
        let isGated = false

        Button {
            dismissKeyboard()
            if isGated {
                paywallReason = .proFeatureGated(name: preset.title + " tone")
                showingPaywall = true
            } else {
                engine.tonePreset = preset
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(preset.title)
                    .font(.caption.weight(isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcript

    /// Two-way binding that writes back to whichever engine property
    /// the UI is currently showing. Lets the user freely edit the
    /// transcript with a real cursor after dictation finishes.
    private var transcriptBinding: Binding<String> {
        Binding(
            get: {
                engine.polishedTranscript.isEmpty
                    ? engine.liveTranscript
                    : engine.polishedTranscript
            },
            set: { newValue in
                if engine.polishedTranscript.isEmpty {
                    engine.liveTranscript = newValue
                } else {
                    engine.polishedTranscript = newValue
                }
            }
        )
    }

    private var transcriptArea: some View {
        ZStack(alignment: .topLeading) {
            SelectableTextView(
                text: transcriptBinding,
                selectedRange: $selectedRange,
                isFocused: $transcriptFocused,
                isEditable: !engine.isRecording,
                placeholder: "Tap the mic and start speaking. Your words will appear here in real time."
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Give the transcript area the remaining vertical space in the
        // parent VStack so it grows to fill whatever's left.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 140)
    }

    // MARK: - Action bar

    /// Fixed-width 7-column action row. No horizontal scrolling —
    /// every button is visible without scrolling on any iPhone size.
    private var actionBar: some View {
        HStack(spacing: 4) {
            ActionButton(
                title: "Select",
                systemImage: "selection.pin.in.out"
            ) {
                // Select all in the transcript via responder chain.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.selectAll(_:)),
                    to: nil, from: nil, for: nil
                )
                // Also set our state-mirror to the full range so the
                // Re-dictate button enables even if UIKit's callback
                // lags.
                let ns = visibleTranscript as NSString
                selectedRange = NSRange(location: 0, length: ns.length)
            }
            .disabled(visibleTranscript.isEmpty)

            ActionButton(title: "Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = visibleTranscript
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            .disabled(visibleTranscript.isEmpty)

            ActionButton(title: "Clear", systemImage: "xmark.circle") {
                dismissKeyboard()
                engine.clearBuffers()
                selectedRange = NSRange(location: 0, length: 0)
            }
            .disabled(visibleTranscript.isEmpty)

            ActionButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                engine.revertToRaw()
            }
            .disabled(!isShowingPolished || engine.isRecording)

            ActionButton(title: "Redo", systemImage: "arrow.uturn.forward") {
                engine.redoPolish()
            }
            .disabled(
                isShowingPolished
                    || engine.cachedPolishedTranscript.isEmpty
                    || engine.isRecording
            )

            ActionButton(title: "Share", systemImage: "square.and.arrow.up") {
                showingShareSheet = true
            }
            .disabled(visibleTranscript.isEmpty)

            // Highlight-to-redictate: user selects text, taps this,
            // speaks a replacement, and the selected range gets
            // spliced with the cleaned new speech.
            ActionButton(
                title: "Re-dictate",
                systemImage: "mic.badge.plus",
                accent: hasSelection
            ) {
                startRedictateSelection()
            }
            .disabled(!hasSelection || engine.isRecording)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// Kick off a replacement dictation for the currently selected
    /// range. Drops keyboard focus, snapshots the current transcript
    /// + selection, and asks the engine to start fresh.
    private func startRedictateSelection() {
        let base = visibleTranscript
        let range = selectedRange
        guard range.length > 0 else { return }
        dismissKeyboard()
        Task {
            await engine.startReplacingSelection(in: base, range: range)
        }
    }

    // MARK: - Mic control bar

    private var controlBar: some View {
        VStack(spacing: 8) {
            if engine.isPolishing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Polishing transcript…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                dismissKeyboard()
                Task {
                    if engine.isRecording {
                        await engine.stop()
                    } else {
                        await engine.start()
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(engine.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 78, height: 78)
                        .shadow(radius: engine.isRecording ? 8 : 4)

                    Image(systemName: engine.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(engine.isRecording ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: engine.isRecording)
            .accessibilityLabel(engine.isRecording ? "Stop dictation" : "Start dictation")

            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.thinMaterial)
    }

    private var statusLine: String {
        if engine.isReplacingSelection && engine.isRecording {
            return "Re-dictating selection… tap to stop"
        }
        if engine.isReplacingSelection && engine.isPolishing {
            return "Splicing replacement…"
        }
        if engine.isRecording { return "Recording… tap to stop" }
        if engine.isPolishing { return "Cleaning up…" }
        if isShowingPolished { return "Polished • tap Undo for raw" }
        if !engine.liveTranscript.isEmpty { return "Raw transcript" }
        return "Ready"
    }

    // MARK: - Command confirmation pill

    @ViewBuilder
    private var commandConfirmationPill: some View {
        if let cmd = engine.lastCommandConfirmation {
            Text("✓ \(cmd)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .shadow(radius: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation { engine.lastCommandConfirmation = nil }
                }
        }
    }
}

// MARK: - Reusable action button

private struct ActionButton: View {
    let title: String
    let systemImage: String
    var accent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(accent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent ? Color.accentColor : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SelectableTextView (UITextView wrapper)

/// UIViewRepresentable wrapper around UITextView so we can observe
/// `selectedRange` and enable the highlight-to-redictate flow.
/// SwiftUI's built-in TextEditor does not expose selection in iOS 17,
/// and we target 17+, so we drop to UIKit.
struct SelectableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var isFocused: FocusState<Bool>.Binding
    var isEditable: Bool
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .title3)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.textContainer.lineFragmentPadding = 0
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.returnKeyType = .default
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        // Placeholder is faked via a layer-label child since
        // UITextView has no native placeholder.
        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: tv.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 8),
            placeholderLabel.trailingAnchor.constraint(equalTo: tv.trailingAnchor, constant: -8),
        ])
        context.coordinator.placeholderLabel = placeholderLabel
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Avoid clobbering the user's in-progress edit: only rewrite
        // text when it actually differs from what UITextView has.
        if tv.text != text {
            tv.text = text
        }
        tv.isEditable = isEditable
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        // Sync selection back into the view if SwiftUI state changed
        // externally (e.g. Select All button).
        if tv.selectedRange != selectedRange {
            let ns = tv.text as NSString
            let safe = NSRange(
                location: min(selectedRange.location, ns.length),
                length: min(selectedRange.length, max(0, ns.length - min(selectedRange.location, ns.length)))
            )
            if safe.location != tv.selectedRange.location
                || safe.length != tv.selectedRange.length {
                tv.selectedRange = safe
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextView
        weak var placeholderLabel: UILabel?

        init(_ parent: SelectableTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Push the new selection back up into SwiftUI state so
            // the Re-dictate button can enable/disable correctly.
            DispatchQueue.main.async {
                self.parent.selectedRange = textView.selectedRange
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.isFocused.wrappedValue = false
            }
        }
    }
}

// MARK: - UIActivityViewController bridge for Share

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    DictationView()
        .environmentObject(DictationEngine())
        .environmentObject(VocabPackManager())
        .environmentObject(EntitlementManager.shared)
        .environmentObject(DictationHistoryStore())
        .environmentObject(PasteTargetsManager())
        .environmentObject(AppSettings())
}
