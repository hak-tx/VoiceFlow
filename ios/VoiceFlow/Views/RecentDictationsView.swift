//
//  RecentDictationsView.swift
//  VoiceFlow
//
//  Shows the user's recent Quick Dictate sessions. Free tier sees
//  the last 5 entries; Pro sees up to 20. Each row has one-tap
//  "copy again" and "share" buttons. A Shortcuts intent
//  ("Get Last Dictation") returns `history.mostRecent()` so
//  automation flows can grab the most recent polished text without
//  opening the app.
//

import SwiftUI
import UIKit

struct RecentDictationsView: View {
    @EnvironmentObject var history: DictationHistoryStore
    @EnvironmentObject var entitlements: EntitlementManager
    @Environment(\.dismiss) private var dismiss

    @State private var shareItem: ShareItem?
    @State private var showingPaywall = false

    private var visible: [DictationHistoryEntry] {
        history.visibleEntries()
    }

    var body: some View {
        NavigationStack {
            List {
                if visible.isEmpty {
                    Text("No dictations yet. Try Quick Dictate from the home screen or your Action Button.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visible) { entry in
                        HistoryRow(entry: entry, onCopy: copy, onShare: share)
                    }
                }

                if !entitlements.hasPro,
                   history.entries.count > DictationHistoryStore.freeLimit {
                    Section {
                        Button {
                            showingPaywall = true
                        } label: {
                            Label(
                                "Upgrade to Pro to see all \(history.entries.count) recent dictations",
                                systemImage: "lock.fill"
                            )
                        }
                    }
                }
            }
            .navigationTitle("Recent Dictations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !history.entries.isEmpty {
                        Button("Clear") {
                            history.clear()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.text])
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(reason: .proFeatureGated(name: "Full dictation history"))
                    .environmentObject(entitlements)
            }
        }
    }

    private func copy(_ entry: DictationHistoryEntry) {
        let text = entry.polishedTranscript.isEmpty ? entry.rawTranscript : entry.polishedTranscript
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func share(_ entry: DictationHistoryEntry) {
        let text = entry.polishedTranscript.isEmpty ? entry.rawTranscript : entry.polishedTranscript
        shareItem = ShareItem(text: text)
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: DictationHistoryEntry
    let onCopy: (DictationHistoryEntry) -> Void
    let onShare: (DictationHistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.previewSnippet)
                .font(.body)
                .lineLimit(3)
            HStack(spacing: 12) {
                Text(entry.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(entry.tonePreset.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCopy(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Button {
                    onShare(entry)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

#Preview {
    RecentDictationsView()
        .environmentObject(DictationHistoryStore())
        .environmentObject(EntitlementManager.shared)
}
