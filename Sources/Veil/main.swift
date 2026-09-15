import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let controller = VeilController()
    private let hotkeys = Hotkeys()
    private let onboarding = Onboarding()
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hotkeys.toggle = { [weak self] in self?.controller.toggle() }
        controller.changed = { [weak self] in self?.refresh() }
        onboarding.runTest = { [weak self] in
            self?.controller.stop()
            self?.controller.start()
        }
        refresh()
        if !UserDefaults.standard.bool(forKey: "setupSeen") { onboarding.show() }
    }
    private func refresh() {
        let state = controller.armed ? (controller.masks.isEmpty ? "Armed" : "Masking") : "Off"
        item.button?.image = NSImage(systemSymbolName: controller.armed ? "shield.fill" : "shield", accessibilityDescription: "Veil · \(state)")
        let menu = NSMenu()
        menu.addItem(withTitle: "Veil · \(state)", action: nil, keyEquivalent: "")
        let presenting = menu.addItem(withTitle: controller.armed ? "Stop Presenting" : "Start Presenting", action: #selector(toggle), keyEquivalent: "p")
        presenting.target = self
        let mode = menu.addItem(withTitle: controller.feedMode ? "Use Overlay" : "Use Clean Feed", action: #selector(toggleMode), keyEquivalent: "")
        mode.target = self
        if let error = controller.error { menu.addItem(withTitle: error, action: nil, keyEquivalent: "") }
        menu.addItem(withTitle: "Overlay needs a full-display share", action: nil, keyEquivalent: "")
        let setup = menu.addItem(withTitle: "Permissions & Test…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Veil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }
    @objc private func toggleMode() { controller.toggleMode() }
    @objc private func showSetup() { onboarding.show() }
    @objc private func toggle() { controller.toggle() }
    func applicationWillTerminate(_ notification: Notification) { controller.stop() }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
