//
//  UsageTracker.swift
//  VoiceFlow
//
//  Lightweight, local-only analytics. Records dictation counts, total
//  words, average session length, which voice commands and tone
//  presets the user picks, and which vocab packs are active.
//
//  Everything is persisted to UserDefaults. Nothing leaves the device
//  yet. When we add real analytics later, swap the body of the
//  `record*` methods for a Segment / PostHog / Amplitude call — the
//  public surface stays the same.
//

import Foundation

@MainActor
final class UsageTracker: ObservableObject {

    // MARK: - Persisted counters

    @Published private(set) var dictationCount: Int
    @Published private(set) var totalWords: Int
    @Published private(set) var totalSessionSeconds: Double
    @Published private(set) var voiceCommandCounts: [String: Int]
    @Published private(set) var tonePresetCounts: [String: Int]
    @Published private(set) var activePackNames: [String]

    // MARK: - Session bookkeeping

    private var currentSessionStart: Date?

    // MARK: - Keys

    private let kDictationCount   = "VoiceFlow.usage.dictationCount"
    private let kTotalWords       = "VoiceFlow.usage.totalWords"
    private let kTotalSeconds     = "VoiceFlow.usage.totalSeconds"
    private let kVoiceCmdCounts   = "VoiceFlow.usage.voiceCmdCounts"
    private let kTonePresetCounts = "VoiceFlow.usage.tonePresetCounts"
    private let kActivePacks      = "VoiceFlow.usage.activePacks"

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        self.dictationCount   = d.integer(forKey: kDictationCount)
        self.totalWords       = d.integer(forKey: kTotalWords)
        self.totalSessionSeconds = d.double(forKey: kTotalSeconds)
        self.voiceCommandCounts = (d.dictionary(forKey: kVoiceCmdCounts) as? [String: Int]) ?? [:]
        self.tonePresetCounts = (d.dictionary(forKey: kTonePresetCounts) as? [String: Int]) ?? [:]
        self.activePackNames  = d.stringArray(forKey: kActivePacks) ?? []
    }

    // MARK: - Public API

    func recordSessionStart() {
        currentSessionStart = Date()
    }

    func recordSessionStop(finalWordCount: Int) {
        dictationCount += 1
        totalWords += finalWordCount
        if let start = currentSessionStart {
            totalSessionSeconds += Date().timeIntervalSince(start)
        }
        currentSessionStart = nil
        persist()
    }

    func recordCleanup(
        wordCount: Int,
        tonePreset: TonePreset,
        model: ClaudeCleanup.Model
    ) {
        // Cleanup gives us the polished word count; total words uses
        // the raw count from session stop, so we don't double-count.
        tonePresetCounts[tonePreset.rawValue, default: 0] += 1
        persist()
        // TODO: when adding analytics, send a `cleanup_complete` event
        // here with { model, wordCount, tonePreset }.
    }

    func recordVoiceCommand(_ id: String) {
        voiceCommandCounts[id, default: 0] += 1
        persist()
    }

    func recordActivePackChange(_ names: [String]) {
        activePackNames = names
        persist()
    }

    /// Average session length in seconds across all historical sessions.
    var averageSessionLength: Double {
        guard dictationCount > 0 else { return 0 }
        return totalSessionSeconds / Double(dictationCount)
    }

    // MARK: - Persistence

    private func persist() {
        let d = UserDefaults.standard
        d.set(dictationCount, forKey: kDictationCount)
        d.set(totalWords, forKey: kTotalWords)
        d.set(totalSessionSeconds, forKey: kTotalSeconds)
        d.set(voiceCommandCounts, forKey: kVoiceCmdCounts)
        d.set(tonePresetCounts, forKey: kTonePresetCounts)
        d.set(activePackNames, forKey: kActivePacks)
    }
}
