//
//  OverlayPanel.swift
//  VoiceFlowMac
//
//  A tiny floating status pill that appears near the cursor during
//  dictation. Shows ONLY a recording/polishing indicator — the actual
//  text goes directly into the target app at the cursor via
//  AccessibilityTextManager.
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

        let contentView = OverlayPill()
            .environmentObject(engine)

        let hostingView = NSHostingView(rootView: contentView)
        let pillSize = CGSize(width: 140, height: 32)
        hostingView.frame = NSRect(origin: .zero, size: pillSize)

        let panelRect = positionPanel(near: rect, size: pillSize)

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

// MARK: - Tiny status pill

struct OverlayPill: View {
    @EnvironmentObject var engine: MacDictationEngine

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.isPolishing ? Color.orange : Color.red)
                .frame(width: 8, height: 8)

            Text(engine.isPolishing ? "Cleaning up..." : "Recording")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThickMaterial)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}
