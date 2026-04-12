//
//  OverlayPanel.swift
//  VoiceFlowMac
//
//  Floating panel near the cursor during dictation. Shows:
//    - Recording status indicator
//    - Live transcript as the user speaks
//    - "Cleaning up..." while Claude processes
//    - Active tone preset badge
//
//  Non-activating (doesn't steal focus from the target app).
//

import SwiftUI
import AppKit

@MainActor
final class OverlayPanelController: ObservableObject {

    private var panel: NSPanel?

    func show(
        near rect: CGRect,
        engine: MacDictationEngine,
        settings: MacAppSettings
    ) {
        guard settings.showOverlayDuringDictation else { return }

        // Dismiss any existing panel first.
        dismiss()

        let contentView = OverlayContentView()
            .environmentObject(engine)

        let hostingView = NSHostingView(rootView: contentView)
        let panelSize = CGSize(width: 340, height: 120)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)

        let panelRect = positionPanel(near: rect, size: panelSize)

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
        panel.animationBehavior = .utilityWindow

        panel.orderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionPanel(near rect: CGRect, size: CGSize) -> NSRect {
        let cursorPoint = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            return NSRect(origin: .zero, size: size)
        }

        let screenFrame = screen.visibleFrame
        var origin = CGPoint(
            x: rect.minX,
            y: rect.minY - size.height - 8
        )

        if origin.y < screenFrame.minY {
            origin.y = rect.maxY + 8
        }
        if origin.x + size.width > screenFrame.maxX {
            origin.x = screenFrame.maxX - size.width - 8
        }
        if origin.x < screenFrame.minX {
            origin.x = screenFrame.minX + 8
        }

        return NSRect(origin: origin, size: size)
    }
}

// MARK: - Overlay content

struct OverlayContentView: View {
    @EnvironmentObject var engine: MacDictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status + tone
            HStack {
                Circle()
                    .fill(engine.isPolishing ? Color.orange : Color.red)
                    .frame(width: 8, height: 8)

                Text(engine.isPolishing ? "Cleaning up..." : "Recording")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(engine.tonePreset.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }

            // Live transcript
            if engine.liveTranscript.isEmpty && engine.isRecording {
                Text("Listening...")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .italic()
            } else if !engine.liveTranscript.isEmpty {
                ScrollView {
                    Text(engine.liveTranscript)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 70)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
