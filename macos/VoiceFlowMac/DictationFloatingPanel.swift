//
//  DictationFloatingPanel.swift
//  VoiceFlowMac
//
//  A floating, always-on-top NSPanel that displays the live transcript,
//  a waveform indicator, and a stop button while dictation is active.
//
//  Key behaviors:
//   - .floating window level so it stays above all other windows.
//   - .nonactivatingPanel style mask so it doesn't steal focus from
//     the app the user is actually typing in.
//   - canBecomeKey = true so it can receive the Stop button click.
//   - Hosts a SwiftUI DictationPanelContentView via NSHostingView.
//

import AppKit
import SwiftUI
import Combine

// MARK: - NSPanel subclass

final class DictationFloatingPanel: NSPanel {

    private let engine: MacDictationEngine
    private var cancellables = Set<AnyCancellable>()

    init(engine: MacDictationEngine) {
        self.engine = engine

        let contentRect = NSRect(x: 0, y: 0, width: 320, height: 200)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isFloatingPanel = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.backgroundColor = .windowBackgroundColor
        self.hasShadow = true

        // Rounded corners
        self.isOpaque = false
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.cornerRadius = 12
        self.contentView?.layer?.masksToBounds = true

        // Host SwiftUI content
        let hostingView = NSHostingView(
            rootView: DictationPanelContentView(engine: engine, onStop: { [weak self] in
                self?.hidePanel()
            })
        )
        self.contentView = hostingView

        // Auto-hide when recording stops
        engine.$isRecording
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Small delay to let the user see the final state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.hidePanel()
                }
            }
            .store(in: &cancellables)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showPanel() {
        // Position near top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = self.frame
            let x = screenFrame.maxX - panelFrame.width - 20
            let y = screenFrame.maxY - panelFrame.height - 20
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
        self.orderFrontRegardless()
    }

    func hidePanel() {
        self.orderOut(nil)
    }
}

// MARK: - SwiftUI content view

private struct DictationPanelContentView: View {
    @ObservedObject var engine: MacDictationEngine
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Waveform / level indicator
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    WaveformBar(level: barLevel(for: i))
                }
            }
            .frame(height: 40)
            .animation(.easeInOut(duration: 0.1), value: engine.audioLevel)

            // Status
            HStack {
                Circle()
                    .fill(engine.isRecording ? .red : (engine.isPolishing ? .orange : .green))
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.isRecording {
                    Text("Listening...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Live transcript
            ScrollView {
                Text(engine.liveTranscript.isEmpty ? "Start speaking..." : engine.liveTranscript)
                    .font(.body)
                    .foregroundStyle(engine.liveTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)

            // Stop button
            if engine.isRecording {
                Button(action: {
                    engine.stop()
                    onStop()
                }) {
                    Label("Stop Dictation", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else if engine.isPolishing {
                ProgressView("Polishing with Claude...")
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 320)
        .frame(minHeight: 200)
    }

    private var statusText: String {
        if engine.isRecording { return "Recording" }
        if engine.isPolishing { return "Polishing" }
        return "Done"
    }

    private func barLevel(for index: Int) -> CGFloat {
        guard engine.isRecording else { return 0.05 }
        let base = CGFloat(engine.audioLevel)
        // Create a wave effect by offsetting each bar
        let offset = sin(Double(index) * 0.5 + Date().timeIntervalSince1970 * 4) * 0.3
        return max(0.05, min(1.0, base + CGFloat(offset)))
    }
}

// MARK: - Waveform bar

private struct WaveformBar: View {
    let level: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor.opacity(0.7))
            .frame(width: 3, height: max(3, level * 40))
    }
}
