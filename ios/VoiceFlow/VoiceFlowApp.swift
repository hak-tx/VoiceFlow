//
//  VoiceFlowApp.swift
//  VoiceFlow
//
//  App entry point. Wires up the root DictationView and shared
//  environment objects (dictation engine + vocab pack manager).
//

import SwiftUI

@main
struct VoiceFlowApp: App {
    @StateObject private var engine = DictationEngine()
    @StateObject private var vocabManager = VocabPackManager()

    var body: some Scene {
        WindowGroup {
            DictationView()
                .environmentObject(engine)
                .environmentObject(vocabManager)
                .task {
                    await vocabManager.loadInstalledPacks()
                    engine.vocabManager = vocabManager
                }
        }
    }
}
