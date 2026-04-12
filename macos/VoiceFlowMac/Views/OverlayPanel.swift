//
//  OverlayPanel.swift
//  VoiceFlowMac
//
//  Tiny floating status pill near the cursor. Shows "Recording" or
//  "Cleaning up..." — nothing else. The actual transcript goes at
//  the cursor via Accessibility API.
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
        dismiss()

        let contentView = OverlayPill().environmentObject(engine)
        let hostingView = NSHostingView(rootView: contentView)
        let pillSize = CGSize(width: 130, height: 30)
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
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return NSRect(origin: .zero, size: size) }
        let sf = screen.visibleFrame
        var o = CGPoint(x: rect.minX, y: rect.minY - size.height - 8)
        if o.y < sf.minY { o.y = rect.maxY + 8 }
        if o.x + size.width > sf.maxX { o.x = sf.maxX - size.width - 8 }
        if o.x < sf.minX { o.x = sf.minX + 8 }
        return NSRect(origin: o, size: size)
    }
}

struct OverlayPill: View {
    @EnvironmentObject var engine: MacDictationEngine
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.isPolishing ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
            Text(engine.isPolishing ? "Cleaning up..." : "Recording")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThickMaterial))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
