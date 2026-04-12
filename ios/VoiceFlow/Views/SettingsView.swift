//
//  SettingsView.swift
//  VoiceFlow
//
//  Configuration surface. Sections:
//   - Use VoiceFlow at Work (Universal Clipboard explainer — core
//     positioning doc for corporate users)
//   - Quick Dictate (silence threshold, auto-copy toggle)
//   - Paste Targets (link to the PasteTargetsView)
//   - Appearance (Discreet Mode toggle)
//   - Voice Commands (wake word)
//   - Cleanup (tone preset, Pro Polish)
//   - Subscription (tier, word count, upgrade)
//   - Usage (local-only stats)
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var vocabManager: VocabPackManager
    @EnvironmentObject var entitlements: EntitlementManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pasteTargetsManager: PasteTargetsManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingPaywall = false
    @State private var showingPasteTargets = false
    @State private var showingUniversalClipboardGuide = false
    @State private var wakeWordDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingUniversalClipboardGuide = true
                    } label: {
                        HStack {
                            Image(systemName: "laptopcomputer.and.iphone")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use VoiceFlow at Work").font(.headline)
                                Text("Dictate on iPhone, paste on Mac via Universal Clipboard.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Hero workflow")
                }

                Section("Quick Dictate") {
                    HStack {
                        Text("Auto-stop after silence")
                        Spacer()
                        Text("\(String(format: "%.1f", settings.silenceAutoStopSeconds))s")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $settings.silenceAutoStopSeconds,
                        in: 1.0...5.0,
                        step: 0.5
                    )
                    Toggle("Copy to clipboard when done",
                           isOn: $settings.autoCopyAfterQuickDictate)
                }

                Section("Paste Targets") {
                    Button {
                        showingPasteTargets = true
                    } label: {
                        HStack {
                            Label("Configure paste targets", systemImage: "arrow.up.right.square")
                            Spacer()
                            Text("\(pasteTargetsManager.targets.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section("Appearance") {
                    Toggle(isOn: $settings.discreetMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Discreet Mode")
                            Text("Monochrome icon, dark mode, subdued palette. Designed for managed work phones.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Voice Commands") {
                    TextField("Wake word", text: $wakeWordDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onAppear {
                            wakeWordDraft = engine.commandParser?.wakeWord ?? "VoiceFlow"
                        }
                        .onSubmit {
                            let trimmed = wakeWordDraft.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                engine.commandParser?.wakeWord = trimmed
                            }
                        }
                    Text("Say \"\(wakeWordDraft) copy that\" to copy the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Cleanup") {
                    Picker("Tone Preset", selection: $engine.tonePreset) {
                        ForEach(TonePreset.allCases) { preset in
                            HStack {
                                Image(systemName: preset.symbolName)
                                Text(preset.title)
                                if preset.requiresPro && !entitlements.hasPro {
                                    Spacer()
                                    Text("Pro").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(preset)
                        }
                    }
                    .onChange(of: engine.tonePreset) { _, newValue in
                        if newValue.requiresPro && !entitlements.hasPro {
                            engine.tonePreset = .verbatim
                            showingPaywall = true
                        }
                    }

                    Toggle(isOn: $engine.proPolishEnabled) {
                        HStack {
                            Text("Pro Polish (Sonnet 4.6)")
                            if !entitlements.hasPro {
                                Text("Pro").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onChange(of: engine.proPolishEnabled) { _, newValue in
                        if newValue && !entitlements.hasPro {
                            engine.proPolishEnabled = false
                            showingPaywall = true
                        }
                    }
                }

                Section("Subscription") {
                    HStack {
                        Text("Current tier")
                        Spacer()
                        // HACK: hard-coded "Pro" for internal testing.
                        Text("Pro")
                            .foregroundStyle(.secondary)
                    }
                    // HACK: hide free-tier word counter + upgrade CTA
                    // by wrapping in `if false`. Revert before public
                    // release.
                    if false {
                        HStack {
                            Text("Free words remaining today")
                            Spacer()
                            Text("\(entitlements.freeWordsRemaining()) / \(FreeTierLimits.dailyWordLimit)")
                                .foregroundStyle(.secondary)
                        }
                        Button("Upgrade to Pro") {
                            showingPaywall = true
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    Button("Restore Purchases") {
                        Task { await entitlements.restore() }
                    }
                }

                Section("Usage (on-device only)") {
                    if let tracker = engine.usageTracker {
                        Text("Dictations: \(tracker.dictationCount)")
                        Text("Total words: \(tracker.totalWords)")
                        Text("Avg session: \(Int(tracker.averageSessionLength))s")
                    }
                }

                Section {
                    Text("API key is configured in Secrets.swift. See the README for setup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(reason: .manual)
                    .environmentObject(entitlements)
            }
            .sheet(isPresented: $showingPasteTargets) {
                PasteTargetsView()
                    .environmentObject(pasteTargetsManager)
            }
            .sheet(isPresented: $showingUniversalClipboardGuide) {
                UniversalClipboardGuideView()
            }
        }
    }
}

// MARK: - Universal Clipboard guide

struct UniversalClipboardGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)

                    Text("Use VoiceFlow at Work")
                        .font(.largeTitle.bold())

                    Text("The problem")
                        .font(.title3.bold())
                    Text("Most big companies restrict or outright block third-party keyboards in apps like Outlook, Teams, Slack desktop, and any MDM-managed container. That means you can't use a voice-dictation keyboard where you need it most.")

                    Text("The fix: Universal Clipboard")
                        .font(.title3.bold())
                    Text("Apple's Universal Clipboard copies anything on your iPhone clipboard to your Mac automatically, across every app — including locked-down corporate ones. VoiceFlow is designed around that workflow.")

                    stepRow(
                        number: 1,
                        title: "Dictate on iPhone with Quick Dictate",
                        body: "Tap your Action Button, Lock Screen widget, or Quick Dictate in-app. Speak, and let it auto-stop."
                    )
                    stepRow(
                        number: 2,
                        title: "Polished text lands on your iPhone clipboard",
                        body: "VoiceFlow cleans the text with Claude and copies it to UIPasteboard automatically."
                    )
                    stepRow(
                        number: 3,
                        title: "Paste on your Mac, anywhere",
                        body: "Switch to your Mac. Cmd-V in Outlook desktop, Teams, Slack, Salesforce, anywhere. Universal Clipboard carries the text across."
                    )

                    Text("Requirements")
                        .font(.title3.bold())
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("Both devices signed in with the same Apple ID")
                        bullet("Both on the same Wi-Fi network")
                        bullet("Bluetooth enabled on both")
                        bullet("Handoff enabled (Settings → General → AirPlay & Handoff)")
                    }

                    Text("You can also use Quick Dictate on iPhone and paste directly into any iPhone app that permits pasting — even ones that block third-party keyboards.")
                        .italic()
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func stepRow(number: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.title2.bold())
                .frame(width: 32, height: 32)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(DictationEngine())
        .environmentObject(VocabPackManager())
        .environmentObject(EntitlementManager.shared)
        .environmentObject(AppSettings())
        .environmentObject(PasteTargetsManager())
}
