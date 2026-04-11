//
//  PasteTargetsView.swift
//  VoiceFlow
//
//  Lets the user reorder, add, and remove the apps that show up as
//  one-tap buttons in the Quick Dictate confirmation banner. The
//  top 4 targets are pinned to the banner.
//

import SwiftUI

struct PasteTargetsView: View {
    @EnvironmentObject var manager: PasteTargetsManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The top 4 targets appear in the Quick Dictate confirmation banner. Drag to reorder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Paste Targets") {
                    ForEach(manager.targets) { target in
                        HStack {
                            Image(systemName: target.symbolName)
                                .frame(width: 28)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.name).font(.headline)
                                Text(target.urlScheme)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if manager.bannerTargets().contains(where: { $0.id == target.id }) {
                                Text("Pinned")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onMove(perform: manager.move)
                    .onDelete { idx in
                        let targetsToRemove = idx.map { manager.targets[$0] }
                        for t in targetsToRemove { manager.remove(t) }
                    }
                }
            }
            .navigationTitle("Paste Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPasteTargetView()
                    .environmentObject(manager)
            }
        }
    }
}

struct AddPasteTargetView: View {
    @EnvironmentObject var manager: PasteTargetsManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlScheme: String = ""
    @State private var symbolName: String = "app.fill"

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Salesforce", text: $name)
                }
                Section("URL scheme") {
                    TextField("e.g. salesforce1://", text: $urlScheme)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("SF Symbol name") {
                    TextField("e.g. cloud.fill", text: $symbolName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Image(systemName: symbolName)
                        Text("Preview")
                    }
                }
                Section {
                    Text("Use any SF Symbol name as the icon. Browse symbols in Apple's SF Symbols app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Paste Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        let trimmedScheme = urlScheme.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty, !trimmedScheme.isEmpty else { return }
                        let target = PasteTarget(
                            id: UUID().uuidString,
                            name: trimmedName,
                            symbolName: symbolName.isEmpty ? "app.fill" : symbolName,
                            urlScheme: trimmedScheme,
                            bundleId: nil
                        )
                        manager.add(target)
                        dismiss()
                    }
                    .bold()
                    .disabled(name.isEmpty || urlScheme.isEmpty)
                }
            }
        }
    }
}

#Preview {
    PasteTargetsView()
        .environmentObject(PasteTargetsManager())
}
