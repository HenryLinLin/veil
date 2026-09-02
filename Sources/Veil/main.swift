import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let controller = VeilController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        controller.changed = { [weak self] in self?.refresh() }
        refresh()
    }
    private func refresh() {
        let state = controller.armed ? (controller.masks.isEmpty ? "Armed" : "Masking") : "Off"
        item.button?.image = NSImage(systemSymbolName: controller.armed ? "shield.fill" : "shield", accessibilityDescription: "Veil · \(state)")
        let menu = NSMenu()
        menu.addItem(withTitle: "Veil · \(state)", action: nil, keyEquivalent: "")
        let presenting = menu.addItem(withTitle: controller.armed ? "Stop Presenting" : "Start Presenting", action: #selector(toggle), keyEquivalent: "p")
        presenting.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Veil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }
    @objc private func toggle() { controller.toggle() }
    func applicationWillTerminate(_ notification: Notification) { controller.stop() }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
