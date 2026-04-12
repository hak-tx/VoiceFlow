//
//  MacVocabPackManager.swift
//  VoiceFlowMac
//
//  Loads vocab packs from:
//    1. Bundled starter packs (app bundle Resources/*.json)
//    2. Downloaded packs in Application Support/VoiceFlowMac/vocab-packs/
//    3. Custom always-on user-defined vocabulary
//
//  Merges all active packs into system-prompt fragments for Claude
//  and contextual strings for SFSpeechRecognizer.
//

import Foundation

@MainActor
final class MacVocabPackManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var installedPacks: [VocabPack] = []
    @Published private(set) var availableFromCatalog: [VocabPackCatalogEntry] = []
    @Published private(set) var activePackNames: Set<String> = []

    @Published var customTerms: [String] = []
    @Published var customPhrases: [String] = []
    @Published var customPromptHints: String = ""

    @Published private(set) var isRefreshingCatalog: Bool = false
    @Published private(set) var lastCatalogError: String?

    // MARK: - Keys

    private let activeKey = "VoiceFlowMac.activeVocabPacks"
    private let hasAutoActivatedKey = "VoiceFlowMac.hasAutoActivatedPacks"
    private let customTermsKey = "VoiceFlowMac.customVocab.terms"
    private let customPhrasesKey = "VoiceFlowMac.customVocab.phrases"
    private let customHintsKey = "VoiceFlowMac.customVocab.hints"

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: activeKey) ?? []
        self.activePackNames = Set(saved)
        self.customTerms = UserDefaults.standard.stringArray(forKey: customTermsKey) ?? []
        self.customPhrases = UserDefaults.standard.stringArray(forKey: customPhrasesKey) ?? []
        self.customPromptHints = UserDefaults.standard.string(forKey: customHintsKey) ?? ""
    }

    // MARK: - Loading

    func loadInstalledPacks() async {
        var loaded: [VocabPack] = []

        // Application Support packs.
        if let appSupportDir = userPacksDirectory() {
            loaded.append(contentsOf: loadPacks(from: appSupportDir))
        }

        // Bundled starter packs in the app bundle.
        let bundleURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let bundled = loadPacks(from: bundleURL)
        for pack in bundled where !loaded.contains(where: { $0.name == pack.name }) {
            loaded.append(pack)
        }

        // Also check the bundle root for flat .json files.
        let bundleRoot = loadPacks(from: Bundle.main.bundleURL)
        for pack in bundleRoot where !loaded.contains(where: { $0.name == pack.name }) {
            loaded.append(pack)
        }

        // Custom vocab pack.
        if hasAnyCustom {
            loaded.append(customPack)
        }

        self.installedPacks = loaded.sorted { lhs, rhs in
            if lhs.category.sortOrder != rhs.category.sortOrder {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }
            return lhs.name < rhs.name
        }

        // Auto-activate ALL packs on first launch so every industry
        // gets correct terminology out of the box.
        if !UserDefaults.standard.bool(forKey: hasAutoActivatedKey) && !loaded.isEmpty {
            activePackNames = Set(loaded.map { $0.name })
            UserDefaults.standard.set(Array(activePackNames), forKey: activeKey)
            UserDefaults.standard.set(true, forKey: hasAutoActivatedKey)
        }
    }

    private func loadPacks(from directory: URL) -> [VocabPack] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var packs: [VocabPack] = []
        for url in contents where url.pathExtension.lowercased() == "json" {
            let lower = url.lastPathComponent.lowercased()
            if lower == "manifest.json" || lower == "catalog.json" { continue }
            do {
                let data = try Data(contentsOf: url)
                let pack = try JSONDecoder().decode(VocabPack.self, from: data)
                packs.append(pack)
            } catch {
                continue
            }
        }
        return packs
    }

    private func userPacksDirectory() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let packsDir = appSupport
            .appendingPathComponent("VoiceFlowMac", isDirectory: true)
            .appendingPathComponent("vocab-packs", isDirectory: true)
        if !fm.fileExists(atPath: packsDir.path) {
            try? fm.createDirectory(at: packsDir, withIntermediateDirectories: true)
        }
        return packsDir
    }

    // MARK: - Catalog

    func refreshCatalog() async {
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        lastCatalogError = nil

        // Look for a bundled catalog.json first.
        guard let catalogURL = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            return
        }

        do {
            let data = try Data(contentsOf: catalogURL)
            let catalog = try JSONDecoder().decode(VocabPackCatalog.self, from: data)
            let installedNames = Set(installedPacks.map { $0.name })
            self.availableFromCatalog = catalog.packs.filter { entry in
                !installedNames.contains(entry.name)
            }
        } catch {
            lastCatalogError = error.localizedDescription
        }
    }

    func downloadPack(_ entry: VocabPackCatalogEntry) async {
        guard let dir = userPacksDirectory() else { return }
        let target = dir.appendingPathComponent(entry.file)

        if let src = Bundle.main.url(
            forResource: (entry.file as NSString).deletingPathExtension,
            withExtension: "json"
        ) {
            try? FileManager.default.copyItem(at: src, to: target)
        } else {
            lastCatalogError = "Pack \(entry.name) has no download source wired up."
            return
        }

        await loadInstalledPacks()
    }

    // MARK: - Selection

    func toggleActive(_ name: String) {
        if activePackNames.contains(name) {
            activePackNames.remove(name)
        } else {
            activePackNames.insert(name)
        }
        UserDefaults.standard.set(Array(activePackNames), forKey: activeKey)
    }

    private var activePacks: [VocabPack] {
        var packs = installedPacks.filter { activePackNames.contains($0.name) }
        if hasAnyCustom {
            if !packs.contains(where: { $0.name == customPack.name }) {
                packs.append(customPack)
            }
        }
        return packs
    }

    // MARK: - Prompt injection

    func combinedPromptHints() -> String? {
        let hints = activePacks.map { $0.promptHints }.filter { !$0.isEmpty }
        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: " ")
    }

    func combinedTermsBlock() -> String? {
        let merged = activePacks.flatMap { $0.terms + $0.phrases }
        let unique = Array(NSOrderedSet(array: merged)) as? [String] ?? []
        guard !unique.isEmpty else { return nil }
        return unique.map { "- \($0)" }.joined(separator: "\n")
    }

    func combinedContextualStrings() -> [String] {
        let merged = activePacks.flatMap { $0.terms + $0.phrases }
        let unique = Array(NSOrderedSet(array: merged)) as? [String] ?? []
        return Array(unique.prefix(100))
    }

    // MARK: - Custom vocab

    private var hasAnyCustom: Bool {
        !customTerms.isEmpty || !customPhrases.isEmpty || !customPromptHints.isEmpty
    }

    private var customPack: VocabPack {
        VocabPack(
            name: "Custom Vocabulary",
            version: "local",
            description: "Your personal always-on vocabulary.",
            terms: customTerms,
            phrases: customPhrases,
            promptHints: customPromptHints,
            category: .free,
            bundleId: nil
        )
    }

    func saveCustomVocab(terms: [String], phrases: [String], hints: String) {
        self.customTerms = terms
        self.customPhrases = phrases
        self.customPromptHints = hints
        UserDefaults.standard.set(terms, forKey: customTermsKey)
        UserDefaults.standard.set(phrases, forKey: customPhrasesKey)
        UserDefaults.standard.set(hints, forKey: customHintsKey)
    }
}
