//
//  VocabPack.swift
//  VoiceFlowMac
//
//  Data model for a vocabulary pack. Matches the JSON schema used by
//  files in /vocab-packs at the repo root.
//

import Foundation

enum VocabPackCategory: String, Codable, CaseIterable, Identifiable {
    case free
    case pro
    case professional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free:         return "Free"
        case .pro:          return "Pro"
        case .professional: return "Professional"
        }
    }

    var sortOrder: Int {
        switch self {
        case .free:         return 0
        case .pro:          return 1
        case .professional: return 2
        }
    }
}

struct VocabPack: Codable, Hashable, Identifiable {
    let name: String
    let version: String
    let description: String
    let terms: [String]
    let phrases: [String]
    let promptHints: String
    let category: VocabPackCategory
    let bundleId: String?

    var id: String { name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decode(String.self, forKey: .version)
        self.description = try c.decode(String.self, forKey: .description)
        self.terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        self.phrases = try c.decodeIfPresent([String].self, forKey: .phrases) ?? []
        self.promptHints = try c.decodeIfPresent(String.self, forKey: .promptHints) ?? ""
        self.category = try c.decodeIfPresent(VocabPackCategory.self, forKey: .category) ?? .free
        self.bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
    }

    init(
        name: String,
        version: String,
        description: String,
        terms: [String],
        phrases: [String],
        promptHints: String,
        category: VocabPackCategory = .free,
        bundleId: String? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.terms = terms
        self.phrases = phrases
        self.promptHints = promptHints
        self.category = category
        self.bundleId = bundleId
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, description, terms, phrases, promptHints
        case category, bundleId
    }
}

struct VocabPackCatalogEntry: Codable, Identifiable {
    let id: String
    let name: String
    let file: String
    let version: String
    let description: String
    let termCount: Int
    let category: VocabPackCategory

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.file = try c.decode(String.self, forKey: .file)
        self.version = try c.decode(String.self, forKey: .version)
        self.description = try c.decode(String.self, forKey: .description)
        self.termCount = try c.decodeIfPresent(Int.self, forKey: .termCount) ?? 0
        self.category = try c.decodeIfPresent(VocabPackCategory.self, forKey: .category) ?? .free
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, file, version, description, termCount, category
    }
}

struct VocabPackCatalog: Codable {
    let schemaVersion: String
    let updated: String
    let packs: [VocabPackCatalogEntry]
}
