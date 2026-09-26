import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let controller = VeilController()
    private let hotkeys = Hotkeys()
    private let onboarding = Onboarding()
    private let updater = RulePacks()
    private var menuOpen = false
    private var lastView = ""
    private lazy var settings = SettingsWindow(store: controller.store,
        validate: { CoreEngine.validate($0.engineJSON()) }, onSave: { [weak self] in
            self?.controller.reload()
            self?.configureHotkeys()
            self?.refresh(force: true)
        })
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        controller.configure()
        configureHotkeys()
        hotkeys.peek = { [weak self] down in self?.controller.setPeek(down) }
        hotkeys.toggle = { [weak self] in self?.controller.toggle() }
        controller.changed = { [weak self] in self?.refresh() }
        onboarding.runTest = { [weak self] in
            self?.controller.stop(showSummary: false)
            self?.controller.start()
        }
        refresh()
        if !UserDefaults.standard.bool(forKey: "setupSeen") { onboarding.show() }
    }
    private func refresh(force: Bool = false) {
        let state = controller.armed ? (controller.masks.isEmpty ? "Armed" : "Masking") : "Off"
        let view = "\(state)|\(controller.feedMode)|\(controller.peeking)|\(controller.error ?? "")|\(controller.notice ?? "")|\(hotkeys.error ?? "")|\(controller.masks.map { $0.rule + $0.hash }.sorted())"
        guard force || view != lastView else { return }
        let symbol = NSImage(systemSymbolName: controller.armed ? "shield.fill" : "shield", accessibilityDescription: "Veil · \(state)")
        if !controller.masks.isEmpty, let symbol {
            let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
                symbol.draw(in: CGRect(x: 0, y: 1, width: 16, height: 16))
                NSColor.black.setFill()
                NSBezierPath(ovalIn: CGRect(x: 16, y: 0, width: 4, height: 4)).fill()
                return true
            }
            image.isTemplate = true
            item.button?.image = image
        } else { item.button?.image = symbol }
        item.button?.toolTip = "Veil · \(state) · \(controller.masks.count) regions"
        guard !menuOpen else { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Veil · \(state)", action: nil, keyEquivalent: "")
        add(menu, controller.armed ? "Stop Presenting" : "Start Presenting", #selector(toggle))
        add(menu, controller.feedMode ? "Use Overlay" : "Use Clean Feed", #selector(toggleMode))
        if let error = controller.error { menu.addItem(withTitle: error, action: nil, keyEquivalent: "") }
        if let error = hotkeys.error { menu.addItem(withTitle: error, action: nil, keyEquivalent: "") }
        menu.addItem(withTitle: controller.feedMode ? "Share the Veil Feed window" : "Overlay needs a full-display share", action: nil, keyEquivalent: "")
        if let notice = controller.notice { menu.addItem(withTitle: notice, action: nil, keyEquivalent: "") }
        if controller.peeking { menu.addItem(withTitle: "PEEK · Viewers can see secrets", action: nil, keyEquivalent: "") }
        let matches = NSMenu()
        var seen = Set<String>()
        for mask in controller.masks where !mask.hash.isEmpty && mask.rule != "private-key" {
            guard seen.insert(mask.hash).inserted, seen.count <= 12 else { continue }
            let entry = add(matches, "Allow \(mask.rule) · \(mask.app) · \(mask.hash.prefix(6))", #selector(allowValue(_:)))
            entry.representedObject = mask.hash
        }
        if !matches.items.isEmpty {
            let allow = menu.addItem(withTitle: "Mark a match as not secret", action: nil, keyEquivalent: "")
            allow.submenu = matches
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(showSettings), key: ",")
        add(menu, "Permissions & Test…", #selector(showSetup))
        add(menu, "Import Rule Pack…", #selector(importRules))
        let update = add(menu, "Check for Rule Updates…", #selector(updateRules))
        update.isEnabled = controller.store.current.ruleUpdates
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Veil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        lastView = view
    }
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; DispatchQueue.main.async { self.refresh(force: true) } }
    private func configureHotkeys() {
        let p = controller.store.current
        hotkeys.register(present: p.presentKey, peek: p.peekKey, modifiers: p.modifiers)
    }
    @objc private func allowValue(_ item: NSMenuItem) {
        guard let hash = item.representedObject as? String, !controller.store.current.allowedHashes.contains(hash) else { return }
        controller.store.current.allowedHashes.append(hash)
        controller.store.save()
        controller.reload()
    }
    @objc private func importRules() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.json]
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 1_048_576 else { showError("Rule packs must be smaller than 1 MB."); return }
            try installRules(RulePacks.parse(Data(contentsOf: url)))
        } catch { showError(error.localizedDescription) }
    }
    @objc private func updateRules() {
        let p = controller.store.current
        guard p.ruleUpdates, let url = URL(string: p.rulePackURL) else { return }
        updater.fetch(url) { [weak self] result in
            do { try self?.installRules(result.get()) }
            catch { self?.showError(error.localizedDescription) }
        }
    }
    private func installRules(_ rules: [CustomRule]) throws {
        var next = controller.store.current
        let incoming = Set(rules.map(\.id))
        next.customRules.removeAll { incoming.contains($0.id) }
        next.customRules.append(contentsOf: rules)
        if let error = CoreEngine.validate(next.engineJSON()) { showError(error); return }
        controller.store.save(next)
        controller.reload()
        let alert = NSAlert()
        alert.messageText = "Rules updated"
        alert.informativeText = "Loaded \(rules.count) rules. Review or remove them in Settings."
        alert.runModal()
    }
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Veil"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
    @objc private func showSettings() { settings.show() }
    @objc private func toggleMode() { controller.toggleMode() }
    @objc private func showSetup() { onboarding.show() }
    @objc private func toggle() { controller.toggle() }
    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
}
if CommandLine.arguments.contains("--self-test") {
    let destination = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("diagnostics.json")
    do {
        let results = try FeedChecks.run()
        let report = try JSONSerialization.data(withJSONObject: ["passed": true, "checks": results], options: .prettyPrinted)
        try report.write(to: destination, options: .atomic)
        exit(0)
    } catch {
        let report = try! JSONSerialization.data(withJSONObject: ["passed": false, "error": String(describing: error)], options: .prettyPrinted)
        try? report.write(to: destination, options: .atomic)
        exit(1)
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
