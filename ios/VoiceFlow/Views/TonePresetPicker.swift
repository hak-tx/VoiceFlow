//
//  TonePresetPicker.swift
//  VoiceFlow
//
//  Standalone tone preset picker. Currently DictationView uses a
//  confirmationDialog in the action bar for quick access, but this
//  view can be embedded or pushed on a NavigationStack for a fuller,
//  descriptive picker (e.g. from Settings or a long-press gesture).
//

import SwiftUI

struct TonePresetPicker: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var entitlements: EntitlementManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(TonePreset.allCases) { preset in
                    Button {
                        select(preset)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: preset.symbolName)
                                .font(.title3)
                                .frame(width: 28)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(preset.title).font(.headline)
                                    if preset.requiresPro && !entitlements.hasPro {
                                        Text("Pro")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if engine.tonePreset == preset {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Tone Preset")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(reason: .proFeatureGated(name: "Tone presets"))
                    .environmentObject(entitlements)
            }
        }
    }

    private func select(_ preset: TonePreset) {
        if preset.requiresPro && !entitlements.hasPro {
            showingPaywall = true
            return
        }
        engine.tonePreset = preset
        dismiss()
    }
}

#Preview {
    TonePresetPicker()
        .environmentObject(DictationEngine())
        .environmentObject(EntitlementManager.shared)
}
