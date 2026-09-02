import AppKit

private final class MaskView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        if bounds.width >= 80 && bounds.height >= 18 {
            let label = "Hidden by Veil" as NSString
            label.draw(at: NSPoint(x: 6, y: max(2, (bounds.height - 12) / 2)), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

final class OverlayManager {
    private var panels: [NSPanel] = []
    func show(_ masks: [Mask]) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        while panels.count < masks.count {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = true
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = MaskView()
            panels.append(panel)
        }
        for (index, panel) in panels.enumerated() {
            guard index < masks.count else { panel.orderOut(nil); continue }
            let r = masks[index].rect
            panel.setFrame(CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height), display: true)
            panel.orderFrontRegardless()
        }
    }
    func clear() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }
}
