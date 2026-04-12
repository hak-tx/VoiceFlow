//
//  OverlayPanel.swift
//  VoiceFlowMac
//
//  A floating, borderless panel that appears near the user's cursor
//  during dictation. Shows:
//    - Live transcript as the user speaks
//    - Audio level waveform animation
//    - Status (Recording / Polishing / Done)
//    - The active tone preset
//
//  The panel floats above all other windows (including full-screen
//  apps), is non-activating (doesn't steal focus from the target
//  app), and dismisses when dictation ends.
//

import SwiftUI
import AppKit

// MARK: - OverlayPanelController

/// Manages the lifecycle of the floating overlay NSPanel.
@MainActor
final class OverlayPanelController: ObservableObject {

    private var panel: NSPanel?

    /// Show the overlay near the given screen rect (typically the
    /// cursor/selection bounds from AccessibilityTextManager).
    func show(
        near rect: CGRect,
        engine: MacDictationEngine,
        settings: MacAppSettings
    ) {
        guard settings.showOverlayDuringDictation else { return }

        let contentView = OverlayContentView()
            .environmentObject(engine)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 380, height: 160)

        let panelRect = positionPanel(near: rect, size: CGSize(width: 380, height: 160))

        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        panel.orderFront(nil)
        self.panel = panel
    }

    /// Dismiss the overlay.
    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Update the overlay content size if the transcript grows.
    func updateSize(height: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        let newHeight = max(120, min(height, 400))
        frame.size.height = newHeight
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Position the panel below-right of the given rect, staying
    /// on the screen that contains the cursor. Handles multi-monitor.
    private func positionPanel(near rect: CGRect, size: CGSize) -> NSRect {
        // Find the screen that contains the cursor rect. This is
        // critical for multi-monitor setups — NSScreen.main is always
        // the screen with the key window, which might not be where
        // the user's cursor is.
        let cursorPoint = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            return NSRect(origin: .zero, size: size)
        }

        let screenFrame = screen.visibleFrame

        // Try below the cursor, offset slightly right.
        var origin = CGPoint(
            x: rect.minX,
            y: rect.minY - size.height - 8
        )

        // If it would go off the bottom, put it above instead.
        if origin.y < screenFrame.minY {
            origin.y = rect.maxY + 8
        }

        // Keep on screen horizontally.
        if origin.x + size.width > screenFrame.maxX {
            origin.x = screenFrame.maxX - size.width - 8
        }
        if origin.x < screenFrame.minX {
            origin.x = screenFrame.minX + 8
        }

        // Keep on screen vertically.
        if origin.y + size.height > screenFrame.maxY {
            origin.y = screenFrame.maxY - size.height
        }

        return NSRect(origin: origin, size: size)
    }
}

// MARK: - OverlayContentView

/// The SwiftUI content rendered inside the floating panel.
struct OverlayContentView: View {
    @EnvironmentObject var engine: MacDictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status bar
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                // Tone badge
                HStack(spacing: 3) {
                    Image(systemName: engine.tonePreset.symbolName)
                        .font(.system(size: 9))
                    Text(engine.tonePreset.title)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                )
            }

            // Waveform bar (during recording)
            if engine.isRecording {
                WaveformBar(level: engine.audioLevel)
                    .frame(height: 20)
            }

            // Live transcript
            if !engine.liveTranscript.isEmpty || !engine.polishedTranscript.isEmpty {
                ScrollView {
                    Text(engine.visibleTranscript)
                        .font(.system(size: 13))
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            } else if engine.isRecording {
                Text("Listening...")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .italic()
            }

            // Polishing indicator
            if engine.isPolishing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Cleaning up with Claude...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private var statusColor: Color {
        if engine.isRecording { return .red }
        if engine.isPolishing { return .orange }
        return .green
    }

    private var statusText: String {
        if engine.isReplacingSelection && engine.isRecording {
            return "RE-DICTATING SELECTION"
        }
        if engine.isRecording { return "RECORDING" }
        if engine.isPolishing { return "POLISHING" }
        if !engine.polishedTranscript.isEmpty { return "DONE" }
        return "READY"
    }
}

// MARK: - WaveformBar

/// Simple animated waveform driven by the audio level.
struct WaveformBar: View {
    let level: Float
    private let barCount = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: i))
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(level)
        // Create a wave-like pattern with the center bars tallest.
        let center = CGFloat(barCount) / 2.0
        let distance = abs(CGFloat(index) - center) / center
        let base: CGFloat = 3.0
        let maxHeight: CGFloat = 18.0
        let variation = sin(Double(index) * 0.7 + Double(level) * 10.0) * 0.3 + 0.7
        return base + (maxHeight - base) * normalized * (1.0 - distance * 0.5) * CGFloat(variation)
    }

    private func barColor(for index: Int) -> Color {
        let intensity = Double(level)
        if intensity > 0.7 {
            return .red.opacity(0.8)
        } else if intensity > 0.4 {
            return .orange.opacity(0.7)
        }
        return Color.accentColor.opacity(0.6)
    }
}
