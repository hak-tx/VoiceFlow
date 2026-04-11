//
//  DictationView.swift
//  VoiceFlow
//
//  Primary UI: a big mic button, a scrolling transcript area that shows
//  the live stream while recording and then swaps to the AI-polished
//  version once cleanup completes, and an undo button that reverts the
//  visible transcript back to the raw version.
//

import SwiftUI

struct DictationView: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var vocabManager: VocabPackManager

    @State private var showingPacks = false

    /// Text shown in the transcript area. Prefers the polished version
    /// once it's available; otherwise falls back to the live stream.
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
                transcriptArea
                Divider()
                controlBar
            }
            .navigationTitle("VoiceFlow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPacks = true
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .accessibilityLabel("Vocab packs")
                }
            }
            .sheet(isPresented: $showingPacks) {
                VocabPackPickerView()
                    .environmentObject(vocabManager)
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

    // MARK: - Transcript

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if visibleTranscript.isEmpty {
                        Text("Tap the mic and start speaking. Your words will appear here in real time.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        Text(visibleTranscript)
                            .font(.system(.title3, design: .default))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .id("transcript-bottom")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: visibleTranscript) { _, _ in
                withAnimation {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        VStack(spacing: 16) {
            if engine.isPolishing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Polishing transcript…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                // Undo - revert polished -> raw
                Button {
                    engine.revertToRaw()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 32, weight: .regular))
                }
                .disabled(!isShowingPolished || engine.isRecording)
                .accessibilityLabel("Revert to raw transcript")

                // Main mic button
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

                // Copy to clipboard
                Button {
                    UIPasteboard.general.string = visibleTranscript
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 28, weight: .regular))
                }
                .disabled(visibleTranscript.isEmpty)
                .accessibilityLabel("Copy transcript")
            }

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .background(.thinMaterial)
    }

    private var statusLine: String {
        if engine.isRecording { return "Recording… tap to stop" }
        if engine.isPolishing { return "Cleaning up…" }
        if isShowingPolished { return "Polished • tap undo to see raw" }
        if !engine.liveTranscript.isEmpty { return "Raw transcript" }
        return "Ready"
    }
}

// MARK: - Vocab pack picker

struct VocabPackPickerView: View {
    @EnvironmentObject var vocabManager: VocabPackManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Installed packs") {
                    if vocabManager.installedPacks.isEmpty {
                        Text("No packs installed yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vocabManager.installedPacks, id: \.name) { pack in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(pack.name).font(.headline)
                                    Text(pack.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if vocabManager.activePackNames.contains(pack.name) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vocabManager.toggleActive(pack.name)
                            }
                        }
                    }
                }

                Section {
                    Text("Drop additional .json packs into the app's Documents directory to make them available here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Vocab Packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    DictationView()
        .environmentObject(DictationEngine())
        .environmentObject(VocabPackManager())
}
