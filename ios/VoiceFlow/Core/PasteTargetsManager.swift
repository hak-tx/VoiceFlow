//
//  PasteTargetsManager.swift
//  VoiceFlow
//
//  Tracks the user's configured "paste destination" apps and
//  exposes the top N as banner buttons after Quick Dictate finishes.
//  Persisted in UserDefaults as JSON.
//

import Foundation
import UIKit

@MainActor
final class PasteTargetsManager: ObservableObject {

    @Published var targets: [PasteTarget] = []

    /// Maximum targets surfaced in the Quick Dictate banner. The
    /// full list is always available in settings.
    static let bannerCapacity = 4

    private let storageKey = "VoiceFlow.pasteTargets"

    init() {
        load()
        if targets.isEmpty {
            targets = PasteTarget.defaults
            save()
        }
    }

    // MARK: - CRUD

    func add(_ target: PasteTarget) {
        targets.append(target)
        save()
    }

    func remove(_ target: PasteTarget) {
        targets.removeAll { $0.id == target.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        targets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Top N targets shown in the Quick Dictate confirmation banner.
    func bannerTargets() -> [PasteTarget] {
        Array(targets.prefix(Self.bannerCapacity))
    }

    // MARK: - Launch

    /// Open the given target's URL scheme. Returns true if the
    /// system accepted the URL. The clipboard should already hold
    /// the polished transcript by the time this is called.
    @discardableResult
    func launch(_ target: PasteTarget) async -> Bool {
        guard let url = URL(string: target.urlScheme),
              UIApplication.shared.canOpenURL(url) else {
            return false
        }
        return await UIApplication.shared.open(url)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PasteTarget].self, from: data) else {
            return
        }
        self.targets = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
