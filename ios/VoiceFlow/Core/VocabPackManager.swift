//
//  VocabPackManager.swift
//  VoiceFlow
//
//  Full vocab pack system. Responsibilities:
//   - Load packs from three sources:
//       1. Bundled starter packs (Resources/*.json)
//       2. Downloaded packs in Documents/vocab-packs/*.json
//       3. A special "custom" always-on local pack built from the
//          user's own terms
//   - Fetch a remote catalog manifest and diff it against installed
//     packs to surface downloadable packs in the picker.
//   - Enable/disable individual packs (persisted).
//   - Merge all active packs' promptHints + terms/phrases into a
//     single system-prompt fragment for ClaudeCleanup.
//
//  Note: the remote catalog URL is currently a stub pointing at a
//  local file. See `remoteCatalogURL` below.
//

import Foundation

@MainActor
final class VocabPackManager: ObservableObject {

    // MARK: - Published state

    /// All packs known to be installed on device (bundled + downloaded
    /// + custom).
    @Published private(set) var installedPacks: [VocabPack] = []

    /// Packs the remote catalog says exist but which aren't installed
    /// on device yet. Populated by `refreshCatalog()`.
    @Published private(set) var availableFromCatalog: [VocabPackCatalogEntry] = []

    /// Names of packs the user has toggled on. Persisted in
    /// UserDefaults.
    @Published private(set) var activePackNames: Set<String> = []

    /// The always-on user-defined vocab. Synthesized into a pack on
    /// save. Pro-gated at the callsite.
    @Published var customTerms: [String] = []
    @Published var customPhrases: [String] = []
    @Published var customPromptHints: String = ""

    /// Download / refresh status for the picker.
    @Published private(set) var isRefreshingCatalog: Bool = false
    @Published private(set) var lastCatalogError: String?

    // MARK: - Injected

    weak var entitlements: EntitlementManager?
    weak var usageTracker: UsageTracker?

    // MARK: - Keys

    private let activeKey = "VoiceFlow.activeVocabPacks"
    private let customTermsKey = "VoiceFlow.customVocab.terms"
    private let customPhrasesKey = "VoiceFlow.customVocab.phrases"
    private let customHintsKey = "VoiceFlow.customVocab.hints"

    /// Stub catalog URL. In production, point this at a CDN JSON file
    /// served alongside the /vocab-packs folder; for now we treat
    /// `file:///` URLs and bundle resources as valid catalog sources.
    // TODO: replace with a real HTTPS URL once we have a CDN.
    static let remoteCatalogURL: URL = {
        if let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json") {
            return bundled
        }
        return URL(string: "https://voiceflow.invalid/catalog.json")!
    }()

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: activeKey) ?? []
        self.activePackNames = Set(saved)
        self.customTerms = UserDefaults.standard.stringArray(forKey: customTermsKey) ?? []
        self.customPhrases = UserDefaults.standard.stringArray(forKey: customPhrasesKey) ?? []
        self.customPromptHints = UserDefaults.standard.string(forKey: customHintsKey) ?? ""
    }

    // MARK: - Loading

    /// Reads every .json file in Documents/vocab-packs/ plus every
    /// .json file in the app bundle's Resources, synthesizes the
    /// custom pack, and publishes the merged installed list.
    func loadInstalledPacks() async {
        var loaded: [VocabPack] = []

        if let docsDir = userPacksDirectory() {
            loaded.append(contentsOf: loadPacks(from: docsDir))
        }

        // Bundled starter packs live at the top level of the main
        // bundle (see Resources/*.json in the Xcode project).
        let bundleURL = Bundle.main.bundleURL
        let bundled = loadPacks(from: bundleURL)
        for pack in bundled where !loaded.contains(where: { $0.name == pack.name }) {
            loaded.append(pack)
        }

        // Synthesize the custom pack if it has any content and the
        // user is Pro (custom vocab is Pro-only).
        if let entitlements, entitlements.hasPro, hasAnyCustom {
            loaded.append(customPack)
        }

        self.installedPacks = loaded.sorted { lhs, rhs in
            if lhs.category.sortOrder != rhs.category.sortOrder {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }
            return lhs.name < rhs.name
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

    // MARK: - Remote catalog

    /// Fetch the (stub) remote catalog and compute which packs in it
    /// aren't already installed. The user's picker view reads
    /// `availableFromCatalog` to show the "Download" column.
    func refreshCatalog() async {
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        lastCatalogError = nil

        do {
            let data: Data
            if Self.remoteCatalogURL.isFileURL {
                data = try Data(contentsOf: Self.remoteCatalogURL)
            } else {
                let (d, _) = try await URLSession.shared.data(from: Self.remoteCatalogURL)
                data = d
            }
            let catalog = try JSONDecoder().decode(VocabPackCatalog.self, from: data)
            let installedNames = Set(installedPacks.map { $0.name })
            self.availableFromCatalog = catalog.packs.filter { entry in
                !installedNames.contains(entry.name)
            }
        } catch {
            lastCatalogError = error.localizedDescription
        }
    }

    /// Download (or copy, for stub catalogs) a pack into the
    /// Documents directory so it becomes available on next load.
    func downloadPack(_ entry: VocabPackCatalogEntry) async {
        // TODO: real download. For now we look for the file at the
        // repo's /vocab-packs folder via bundle resource, which is how
        // the simulator seed case works.
        guard let docsDir = userPacksDirectory() else { return }
        let target = docsDir.appendingPathComponent(entry.file)

        if let src = Bundle.main.url(
            forResource: (entry.file as NSString).deletingPathExtension,
            withExtension: "json"
        ) {
            try? FileManager.default.copyItem(at: src, to: target)
        } else {
            // Future: actually hit the network.
            lastCatalogError = "Pack \(entry.name) has no download source wired up."
            return
        }

        await loadInstalledPacks()
    }

    // MARK: - Selection

    func toggleActive(_ name: String, reason: PaywallReason? = nil) {
        // Pro-gated packs can only be activated by Pro users.
        if let pack = installedPacks.first(where: { $0.name == name }),
           pack.category != .free,
           let entitlements, !entitlements.hasPro {
            // Caller is expected to surface the paywall with the
            // reason; we just no-op here to avoid silently flipping
            // the state.
            return
        }

        if activePackNames.contains(name) {
            activePackNames.remove(name)
        } else {
            activePackNames.insert(name)
        }
        UserDefaults.standard.set(
            Array(activePackNames),
            forKey: activeKey
        )
        usageTracker?.recordActivePackChange(Array(activePackNames))
    }

    private var activePacks: [VocabPack] {
        var packs = installedPacks.filter { activePackNames.contains($0.name) }
        // Custom pack is always on for Pro users (if it exists).
        if let entitlements, entitlements.hasPro, hasAnyCustom {
            if !packs.contains(where: { $0.name == customPack.name }) {
                packs.append(customPack)
            }
        }
        return packs
    }

    // MARK: - Prompt injection

    /// Sentence(s) summarizing the speaker's domain, formed by joining
    /// every active pack's `promptHints`. Appended to the cleanup
    /// system prompt.
    func combinedPromptHints() -> String? {
        let hints = activePacks
            .map { $0.promptHints }
            .filter { !$0.isEmpty }
        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: " ")
    }

    /// Bullet list of every term + phrase from every active pack,
    /// de-duplicated.
    func combinedTermsBlock() -> String? {
        let merged = activePacks.flatMap { $0.terms + $0.phrases }
        let unique = Array(NSOrderedSet(array: merged)) as? [String] ?? []
        guard !unique.isEmpty else { return nil }
        return unique.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: - Custom vocab (Pro)

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
            category: .pro,
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
