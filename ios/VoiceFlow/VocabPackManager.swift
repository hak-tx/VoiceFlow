//
//  VocabPackManager.swift
//  VoiceFlow
//
//  Loads vocab packs from the app's Documents directory (or the bundled
//  seed copies if none are installed), lets the user toggle which ones
//  are "active", and exposes the merged terms/prompt-hints that the
//  DictationEngine injects into its cleanup system prompt.
//
//  Pack schema (matches /vocab-packs/*.json at the repo root):
//  {
//    "name": "...",
//    "version": "...",
//    "description": "...",
//    "terms": ["..."],
//    "phrases": ["..."],
//    "promptHints": "..."
//  }
//

import Foundation

struct VocabPack: Codable, Hashable {
    let name: String
    let version: String
    let description: String
    let terms: [String]
    let phrases: [String]
    let promptHints: String
}

@MainActor
final class VocabPackManager: ObservableObject {

    /// Packs we've successfully loaded from disk.
    @Published private(set) var installedPacks: [VocabPack] = []

    /// Names of packs the user has toggled on. Persisted in UserDefaults.
    @Published private(set) var activePackNames: Set<String> = []

    private let activeKey = "VoiceFlow.activeVocabPacks"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: activeKey) ?? []
        self.activePackNames = Set(saved)
    }

    // MARK: - Loading

    /// Reads every .json file in `Documents/vocab-packs/` as a pack.
    /// Falls back to bundled seed packs (copied in from the repo-level
    /// /vocab-packs folder) on first launch.
    func loadInstalledPacks() async {
        var loaded: [VocabPack] = []

        // 1. User-installed packs live in Documents/vocab-packs/.
        if let docsDir = userPacksDirectory() {
            loaded.append(contentsOf: loadPacks(from: docsDir))
        }

        // 2. Anything bundled with the app (seed packs).
        if let bundleDir = Bundle.main.url(
            forResource: "vocab-packs",
            withExtension: nil
        ) {
            let bundled = loadPacks(from: bundleDir)
            for pack in bundled where !loaded.contains(where: { $0.name == pack.name }) {
                loaded.append(pack)
            }
        }

        self.installedPacks = loaded.sorted { $0.name < $1.name }
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
            // Skip manifest files - they just list available packs.
            if url.lastPathComponent.lowercased() == "manifest.json" { continue }
            do {
                let data = try Data(contentsOf: url)
                let pack = try JSONDecoder().decode(VocabPack.self, from: data)
                packs.append(pack)
            } catch {
                // Silently skip malformed files; real app could log.
                continue
            }
        }
        return packs
    }

    private func userPacksDirectory() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let packsDir = docs.appendingPathComponent("vocab-packs", isDirectory: true)
        if !fm.fileExists(atPath: packsDir.path) {
            try? fm.createDirectory(at: packsDir, withIntermediateDirectories: true)
        }
        return packsDir
    }

    // MARK: - Selection

    func toggleActive(_ name: String) {
        if activePackNames.contains(name) {
            activePackNames.remove(name)
        } else {
            activePackNames.insert(name)
        }
        UserDefaults.standard.set(
            Array(activePackNames),
            forKey: activeKey
        )
    }

    private var activePacks: [VocabPack] {
        installedPacks.filter { activePackNames.contains($0.name) }
    }

    // MARK: - Prompt injection

    /// A single sentence (or joined sentences) to append to the cleanup
    /// system prompt describing the active domain(s).
    func combinedPromptHints() -> String? {
        let hints = activePacks
            .map { $0.promptHints }
            .filter { !$0.isEmpty }
        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: " ")
    }

    /// A newline-separated bullet list of every term + phrase from every
    /// active pack. The cleanup prompt tells Claude to preserve these
    /// verbatim.
    func combinedTermsBlock() -> String? {
        let allTerms = activePacks.flatMap { $0.terms }
        let allPhrases = activePacks.flatMap { $0.phrases }
        let merged = (allTerms + allPhrases)
        guard !merged.isEmpty else { return nil }
        return merged.map { "- \($0)" }.joined(separator: "\n")
    }
}
