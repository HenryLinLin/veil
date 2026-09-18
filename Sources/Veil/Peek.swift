import AppKit

final class PeekWarning {
    private var panel: NSPanel?
    func show() {
        guard panel == nil else { return }
        let frame = NSScreen.main?.visibleFrame ?? .zero
        let window = NSPanel(contentRect: CGRect(x: frame.midX - 220, y: frame.maxY - 72, width: 440, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .systemRed
        let text = NSTextField(labelWithString: "PEEK · Viewers can see secrets too")
        text.font = .systemFont(ofSize: 18, weight: .bold)
        text.textColor = .white
        text.alignment = .center
        text.frame = CGRect(x: 10, y: 16, width: 420, height: 24)
        window.contentView?.addSubview(text)
        window.orderFrontRegardless()
        panel = window
    }
    func hide() { panel?.close(); panel = nil }
}
