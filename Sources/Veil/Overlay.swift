import AppKit

private final class MaskView: NSView {
    private var regions: [CGRect] = []
    func update(_ next: [CGRect]) {
        guard regions != next else { return }
        regions = next
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = NSColor(white: dark ? 0.12 : 0.94, alpha: 1)
        for rect in regions {
            fill.setFill()
            rect.fill()
            if rect.width >= 80 && rect.height >= 18 {
                ("Hidden by Veil" as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - 6), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: dark ? NSColor.lightGray : NSColor.darkGray])
            }
        }
    }
}

final class OverlayManager {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    func show(_ masks: [Mask]) {
        let screens = NSScreen.screens
        let ids = Set(screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
        for id in Array(panels.keys) where !ids.contains(id) { panels.removeValue(forKey: id)?.close() }
        for screen in screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let panel: NSPanel
            if let existing = panels[id] { panel = existing }
            else {
                panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.contentView = MaskView(frame: NSRect(origin: .zero, size: screen.frame.size))
                panels[id] = panel
            }
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
            let display = CGDisplayBounds(id)
            let local = masks.compactMap { mask -> CGRect? in
                let r = mask.rect.intersection(display)
                guard !r.isNull, !r.isEmpty else { return nil }
                return CGRect(x: r.minX - display.minX, y: display.maxY - r.maxY, width: r.width, height: r.height)
            }
            (panel.contentView as? MaskView)?.update(local)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
    func clear() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
}
