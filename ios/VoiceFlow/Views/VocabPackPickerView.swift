//
//  VocabPackPickerView.swift
//  VoiceFlow
//
//  Shows installed vocab packs grouped by category (Free / Pro /
//  Professional), plus a "Available to download" section pulled from
//  the remote catalog. Users can toggle packs on/off, download packs
//  from the catalog, and edit their custom vocabulary.
//

import SwiftUI

struct VocabPackPickerView: View {
    @EnvironmentObject var vocabManager: VocabPackManager
    @EnvironmentObject var entitlements: EntitlementManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingPaywall = false
    @State private var paywallReason: PaywallReason = .manual
    @State private var showingCustomEditor = false

    private var packsByCategory: [VocabPackCategory: [VocabPack]] {
        Dictionary(grouping: vocabManager.installedPacks) { $0.category }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(VocabPackCategory.allCases) { category in
                    if let packs = packsByCategory[category], !packs.isEmpty {
                        Section(category.title) {
                            ForEach(packs) { pack in
                                packRow(pack)
                            }
                        }
                    }
                }

                if !vocabManager.availableFromCatalog.isEmpty {
                    Section("Available to download") {
                        ForEach(vocabManager.availableFromCatalog) { entry in
                            catalogRow(entry)
                        }
                    }
                }

                Section {
                    Button {
                        if entitlements.hasPro {
                            showingCustomEditor = true
                        } else {
                            paywallReason = .customVocabGated
                            showingPaywall = true
                        }
                    } label: {
                        HStack {
                            Label("Custom Vocabulary", systemImage: "pencil.and.list.clipboard")
                            Spacer()
                            if !entitlements.hasPro {
                                Text("Pro")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                Section {
                    Text("Drop additional .json packs into the app's Documents directory (Files → On My iPhone → VoiceFlow → vocab-packs) to make them available here.")
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await vocabManager.refreshCatalog() }
                    } label: {
                        if vocabManager.isRefreshingCatalog {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(reason: paywallReason)
                    .environmentObject(entitlements)
            }
            .sheet(isPresented: $showingCustomEditor) {
                CustomVocabEditor()
                    .environmentObject(vocabManager)
            }
            .task {
                await vocabManager.loadInstalledPacks()
                await vocabManager.refreshCatalog()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func packRow(_ pack: VocabPack) -> some View {
        let isActive = vocabManager.activePackNames.contains(pack.name)
        let isGated = pack.category != .free && !entitlements.hasPro

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name).font(.headline)
                Text(pack.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("v\(pack.version) • \(pack.terms.count) terms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isGated {
                Text("Pro")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.2))
                    .clipShape(Capsule())
            } else if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isGated {
                paywallReason = .packGated(name: pack.name)
                showingPaywall = true
            } else {
                vocabManager.toggleActive(pack.name)
            }
        }
    }

    @ViewBuilder
    private func catalogRow(_ entry: VocabPackCatalogEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.headline)
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                Task { await vocabManager.downloadPack(entry) }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Custom vocab editor (Pro)

struct CustomVocabEditor: View {
    @EnvironmentObject var vocabManager: VocabPackManager
    @Environment(\.dismiss) private var dismiss

    @State private var termsInput: String = ""
    @State private var phrasesInput: String = ""
    @State private var hints: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Terms (one per line)") {
                    TextEditor(text: $termsInput)
                        .frame(minHeight: 120)
                }
                Section("Phrases (one per line)") {
                    TextEditor(text: $phrasesInput)
                        .frame(minHeight: 120)
                }
                Section("Prompt hints") {
                    TextField(
                        "Describe who you are / how you talk",
                        text: $hints,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }
            }
            .navigationTitle("Custom Vocabulary")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        vocabManager.saveCustomVocab(
                            terms: parseLines(termsInput),
                            phrases: parseLines(phrasesInput),
                            hints: hints
                        )
                        Task {
                            await vocabManager.loadInstalledPacks()
                            dismiss()
                        }
                    }
                    .bold()
                }
            }
            .onAppear {
                termsInput = vocabManager.customTerms.joined(separator: "\n")
                phrasesInput = vocabManager.customPhrases.joined(separator: "\n")
                hints = vocabManager.customPromptHints
            }
        }
    }

    private func parseLines(_ s: String) -> [String] {
        s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    VocabPackPickerView()
        .environmentObject(VocabPackManager())
        .environmentObject(EntitlementManager.shared)
}
