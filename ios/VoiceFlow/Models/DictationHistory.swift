//
//  DictationHistory.swift
//  VoiceFlow
//
//  On-device history of the user's recent Quick Dictate sessions.
//  Free tier sees the last 5 entries, Pro sees up to 20, and we
//  enforce the cap by trimming on every save.
//
//  Persisted as a JSON file in the app's Application Support
//  directory so we're not stepping on Documents (which is user-
//  facing via the Files app). Everything is local; nothing is
//  shipped off device.
//

import Foundation

struct DictationHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let rawTranscript: String
    let polishedTranscript: String
    /// Tone preset active when this dictation was cleaned up.
    let tonePreset: String
    /// Vocab pack names active at the time (for later debugging /
    /// reproduction).
    let activePacks: [String]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawTranscript: String,
        polishedTranscript: String,
        tonePreset: String,
        activePacks: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.polishedTranscript = polishedTranscript
        self.tonePreset = tonePreset
        self.activePacks = activePacks
    }

    /// First 60 characters of the polished transcript, used in the
    /// Quick Dictate confirmation banner and the history list.
    var previewSnippet: String {
        let text = polishedTranscript.isEmpty ? rawTranscript : polishedTranscript
        if text.count <= 60 { return text }
        let end = text.index(text.startIndex, offsetBy: 60)
        return String(text[..<end]) + "…"
    }
}

@MainActor
final class DictationHistoryStore: ObservableObject {

    // MARK: - Hard cap

    /// Absolute upper bound regardless of tier. Pro users can see
    /// `freeLimit..<proLimit` entries.
    static let proLimit = 20
    static let freeLimit = 5

    @Published private(set) var entries: [DictationHistoryEntry] = []

    // MARK: - Injected

    weak var entitlements: EntitlementManager?

    // MARK: - Init / IO

    init() {
        load()
    }

    /// Visible slice of entries based on the user's tier.
    func visibleEntries() -> [DictationHistoryEntry] {
        let limit = (entitlements?.hasPro ?? false) ? Self.proLimit : Self.freeLimit
        return Array(entries.prefix(limit))
    }

    func add(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.proLimit {
            entries = Array(entries.prefix(Self.proLimit))
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Most recent entry (used by the "Get Last Dictation" intent).
    func mostRecent() -> DictationHistoryEntry? {
        entries.first
    }

    // MARK: - Storage

    private var fileURL: URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("dictation-history.json")
    }

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([DictationHistoryEntry].self, from: data) {
            self.entries = decoded
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
