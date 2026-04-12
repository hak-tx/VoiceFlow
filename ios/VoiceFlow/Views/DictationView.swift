//
//  DictationView.swift
//  VoiceFlow
//
//  Primary UI. Layout:
//
//    ┌────────────────────────────────┐
//    │            VoiceFlow         📚 │  ← nav bar
//    ├────────────────────────────────┤
//    │                                │
//    │  scrolling transcript area     │
//    │  (live while recording,        │
//    │   polished after cleanup)      │
//    │                                │
//    ├────────────────────────────────┤
//    │ [Select] [Copy] [Clear]        │
//    │ [Undo]   [Share] [Tone]        │  ← action bar
//    ├────────────────────────────────┤
//    │       ◉ ◉ ◉   🎤   ◉ ◉ ◉       │  ← mic button row
//    │         Ready / Recording…     │
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
    @State private var showingTonePicker = false
    @State private var showingShareSheet = false
    @State private var showingQuickDictate = false
    @State private var showingRecent = false
    @State private var paywallReason: PaywallReason = .manual

    /// Dismiss the iOS keyboard if the TextEditor (or any other
    /// input) currently has focus. Called on every tap that isn't
    /// in the TextEditor itself so the keyboard doesn't linger over
    /// the tone / vocab / action UI.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                quickDictateCTA
                toneRow
                vocabPacksCTA
                transcriptArea
                Divider()
                actionBar
                Divider().opacity(0.5)
                controlBar
            }
            .overlay(alignment: .top) { commandConfirmationPill }
            .navigationTitle("VoiceFlow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingRecent = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Recent dictations")
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
            .confirmationDialog(
                "Tone Preset",
                isPresented: $showingTonePicker,
                titleVisibility: .visible
            ) {
                ForEach(TonePreset.allCases) { preset in
                    Button(preset.title) {
                        if preset.requiresPro && !entitlements.hasPro {
                            paywallReason = .proFeatureGated(name: preset.title + " tone")
                            showingPaywall = true
                        } else {
                            engine.tonePreset = preset
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
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

    // MARK: - Quick Dictate CTA (hero slot)

    /// Prominent Quick Dictate button at the top of the screen —
    /// this is the hero interaction per the corporate-clipboard
    /// positioning. The big mic button below is still available for
    /// users who want the traditional "watch me dictate" flow.
    private var quickDictateCTA: some View {
        Button {
            dismissKeyboard()
            showingQuickDictate = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Dictate")
                        .font(.headline)
                    Text("Tap, speak, auto-copy. Under 5 seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Tone preset row

    /// Front-and-center horizontal row of tone presets. Each chip
    /// shows its icon + name; the active one is highlighted. Pro-
    /// only tones are tagged and route to the paywall on tap.
    private var toneRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("TONE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Text("— how aggressively should AI clean up?")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TonePreset.allCases) { preset in
                        toneChip(preset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
        }
        .padding(.bottom, 8)
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
            HStack(spacing: 6) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                Text(preset.title)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                if isGated {
                    Text("PRO")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Vocab packs CTA (Pro upsell)

    /// Explains what vocab packs do and routes to the picker /
    /// paywall. Replaces the old cryptic book icon in the toolbar.
    private var vocabPacksCTA: some View {
        Button {
            dismissKeyboard()
            showingPacks = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(activeVocabPackHeadline)
                            .font(.subheadline.weight(.semibold))
                        // HACK: PRO tag hard-removed for testing.
                        // Revert `if false` -> `if !entitlements.hasPro`
                        // before public release.
                        if false {
                            Text("PRO")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    Text(activeVocabPackSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var activeVocabPackHeadline: String {
        let n = vocabManager.activePackNames.count
        if n == 0 {
            return "Industry Vocabulary"
        }
        return "\(n) vocab pack\(n == 1 ? "" : "s") active"
    }

    private var activeVocabPackSubtitle: String {
        if vocabManager.activePackNames.isEmpty {
            return "Unlock legal, medical, finance, construction terms Claude will preserve verbatim."
        }
        return "Tap to manage. Active packs shape the AI cleanup to your field."
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
            // TextEditor gives us native iOS cursor, selection,
            // copy/paste, magnifier, long-press menu, etc.
            TextEditor(text: transcriptBinding)
                .font(.system(.title3, design: .default))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .disabled(engine.isRecording) // prevent edit while mic live
                .toolbar {
                    // Adds a Done button above the iOS keyboard when
                    // the TextEditor is focused so the user can
                    // dismiss the keyboard without tapping outside.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                        }
                        .font(.headline)
                    }
                }

            // Placeholder text shown when transcript is empty.
            if visibleTranscript.isEmpty {
                Text("Tap the mic and start speaking. Your words will appear here in real time.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        // Give the transcript area the remaining vertical space in
        // the parent VStack. Without this, TextEditor collapses to
        // its intrinsic ~1-line height when there's lots of fixed
        // content above (Quick Dictate CTA, tone row, vocab pack
        // CTA) so the user's dictation appears invisible.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 180)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ActionChip(
                    title: "Select All",
                    systemImage: "selection.pin.in.out"
                ) {
                    // Send UIResponder selectAll up the responder
                    // chain — the focused TextEditor picks it up and
                    // selects its entire contents.
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.selectAll(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .disabled(visibleTranscript.isEmpty)

                ActionChip(
                    title: "Copy",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = visibleTranscript
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                .disabled(visibleTranscript.isEmpty)

                ActionChip(
                    title: "Clear",
                    systemImage: "xmark.circle"
                ) {
                    engine.clearBuffers()
                }
                .disabled(visibleTranscript.isEmpty)

                ActionChip(
                    title: "Undo",
                    systemImage: "arrow.uturn.backward"
                ) {
                    engine.revertToRaw()
                }
                .disabled(!isShowingPolished || engine.isRecording)

                ActionChip(
                    title: "Redo",
                    systemImage: "arrow.uturn.forward"
                ) {
                    engine.redoPolish()
                }
                .disabled(
                    isShowingPolished
                        || engine.cachedPolishedTranscript.isEmpty
                        || engine.isRecording
                )

                ActionChip(
                    title: "Share",
                    systemImage: "square.and.arrow.up"
                ) {
                    showingShareSheet = true
                }
                .disabled(visibleTranscript.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Mic control bar

    private var controlBar: some View {
        VStack(spacing: 10) {
            if engine.isPolishing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Polishing transcript…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
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
                        .frame(width: 96, height: 96)
                        .shadow(radius: engine.isRecording ? 8 : 4)

                    Image(systemName: engine.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(engine.isRecording ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: engine.isRecording)
            .accessibilityLabel(engine.isRecording ? "Stop dictation" : "Start dictation")

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !entitlements.hasPro {
                Text("\(entitlements.freeWordsRemaining()) / \(FreeTierLimits.dailyWordLimit) free words left today")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .background(.thinMaterial)
    }

    private var statusLine: String {
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

// MARK: - Reusable action chip

private struct ActionChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .frame(minWidth: 64, minHeight: 52)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
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
