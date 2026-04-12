//
//  MacVocabPackPickerView.swift
//  VoiceFlowMac
//
//  Shows installed vocab packs grouped by category with toggles.
//  Presented as a popover from the menu bar view. Large, clear
//  options with descriptions — mirrors the iOS picker UX.
//

import SwiftUI

struct MacVocabPackPickerView: View {
    @EnvironmentObject var vocabManager: MacVocabPackManager
    @State private var showingCustomEditor = false

    private var packsByCategory: [VocabPackCategory: [VocabPack]] {
        Dictionary(grouping: vocabManager.installedPacks) { $0.category }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Vocab Packs")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    Task { await vocabManager.refreshCatalog() }
                } label: {
                    if vocabManager.isRefreshingCatalog {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Pack list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(VocabPackCategory.allCases) { category in
                        if let packs = packsByCategory[category], !packs.isEmpty {
                            categorySectionHeader(category)
                            ForEach(packs) { pack in
                                packRow(pack)
                            }
                        }
                    }

                    // Available to download
                    if !vocabManager.availableFromCatalog.isEmpty {
                        categorySectionHeader(label: "Available to Download")
                        ForEach(vocabManager.availableFromCatalog) { entry in
                            catalogRow(entry)
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Custom vocab
                    Button {
                        showingCustomEditor = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pencil.and.list.clipboard")
                                .font(.system(size: 14))
                                .frame(width: 24)
                                .foregroundStyle(.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Custom Vocabulary")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Add your own terms and phrases")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showingCustomEditor) {
            MacCustomVocabEditor()
                .environmentObject(vocabManager)
        }
        .task {
            await vocabManager.loadInstalledPacks()
            await vocabManager.refreshCatalog()
        }
    }

    // MARK: - Section header

    private func categorySectionHeader(_ category: VocabPackCategory) -> some View {
        categorySectionHeader(label: category.title)
    }

    private func categorySectionHeader(label: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Pack row

    private func packRow(_ pack: VocabPack) -> some View {
        let isActive = vocabManager.activePackNames.contains(pack.name)

        return Button {
            vocabManager.toggleActive(pack.name)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 1) {
                    Text(pack.name)
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        Text(pack.description)
                            .lineLimit(1)
                        Text("(\(pack.terms.count) terms)")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Catalog row

    private func catalogRow(_ entry: VocabPackCatalogEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.accentColor)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                Text(entry.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await vocabManager.downloadPack(entry) }
            } label: {
                Text("Install")
                    .font(.system(size: 10, weight: .semibold))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

// MARK: - Custom Vocab Editor

struct MacCustomVocabEditor: View {
    @EnvironmentObject var vocabManager: MacVocabPackManager
    @Environment(\.dismiss) private var dismiss

    @State private var termsInput: String = ""
    @State private var phrasesInput: String = ""
    @State private var hints: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("Custom Vocabulary")
                    .font(.headline)
                Spacer()
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
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()

            Divider()

            Form {
                Section("Terms (one per line)") {
                    TextEditor(text: $termsInput)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
                }

                Section("Phrases (one per line)") {
                    TextEditor(text: $phrasesInput)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
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
            .formStyle(.grouped)
        }
        .frame(width: 440, height: 480)
        .onAppear {
            termsInput = vocabManager.customTerms.joined(separator: "\n")
            phrasesInput = vocabManager.customPhrases.joined(separator: "\n")
            hints = vocabManager.customPromptHints
        }
    }

    private func parseLines(_ s: String) -> [String] {
        s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
