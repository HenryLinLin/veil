import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

struct CustomRule: Codable {
    var id: String
    var pattern: String
    var score: Double
}

struct Preferences: Codable {
    var mode = "overlay"
    var threshold = 0.75
    var known = true
    var generic = true
    var personal = true
    var emails = false
    var phones = false
    var ocr = true
    var autoArm = false
    var delay = 0.5
    var login = false
    var presentKey: UInt32 = 35
    var peekKey: UInt32 = 9
    var modifiers = UInt32(cmdKey | shiftKey)
    var customRules: [CustomRule] = []
    var windowRules = WindowRule.defaults
    var allowedHashes: [String] = []
    var allowedPaths: [String] = []
    var disabledRules: [String] = []
    var rulePackURL = ""
    var ruleUpdates = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, threshold, known, generic, personal, emails, phones, ocr, autoArm, delay, login
        case presentKey, peekKey, modifiers, customRules, windowRules, allowedHashes, allowedPaths
        case disabledRules, rulePackURL, ruleUpdates
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? threshold
        known = try c.decodeIfPresent(Bool.self, forKey: .known) ?? known
        generic = try c.decodeIfPresent(Bool.self, forKey: .generic) ?? generic
        personal = try c.decodeIfPresent(Bool.self, forKey: .personal) ?? personal
        emails = try c.decodeIfPresent(Bool.self, forKey: .emails) ?? emails
        phones = try c.decodeIfPresent(Bool.self, forKey: .phones) ?? phones
        ocr = try c.decodeIfPresent(Bool.self, forKey: .ocr) ?? ocr
        autoArm = try c.decodeIfPresent(Bool.self, forKey: .autoArm) ?? autoArm
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? delay
        login = try c.decodeIfPresent(Bool.self, forKey: .login) ?? login
        presentKey = try c.decodeIfPresent(UInt32.self, forKey: .presentKey) ?? presentKey
        peekKey = try c.decodeIfPresent(UInt32.self, forKey: .peekKey) ?? peekKey
        modifiers = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? modifiers
        customRules = try c.decodeIfPresent([CustomRule].self, forKey: .customRules) ?? customRules
        windowRules = try c.decodeIfPresent([WindowRule].self, forKey: .windowRules) ?? windowRules
        allowedHashes = try c.decodeIfPresent([String].self, forKey: .allowedHashes) ?? allowedHashes
        allowedPaths = try c.decodeIfPresent([String].self, forKey: .allowedPaths) ?? allowedPaths
        disabledRules = try c.decodeIfPresent([String].self, forKey: .disabledRules) ?? disabledRules
        rulePackURL = try c.decodeIfPresent(String.self, forKey: .rulePackURL) ?? rulePackURL
        ruleUpdates = try c.decodeIfPresent(Bool.self, forKey: .ruleUpdates) ?? ruleUpdates
    }
}

final class PreferencesStore {
    private let defaults: UserDefaults
    private let key = "veil.preferences.v1"
    var current: Preferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }

    @discardableResult
    func save(_ preferences: Preferences) -> Bool {
        guard let data = try? JSONEncoder().encode(preferences) else { return false }
        defaults.set(data, forKey: key)
        current = preferences
        return true
    }

    @discardableResult
    func save() -> Bool { save(current) }
}

private final class SettingsContent: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    private let store: PreferencesStore
    private let validate: (Preferences) -> String?
    private let onSave: () -> Void
    private var window: NSWindow!
    private let mode = NSPopUpButton()
    private let threshold = NSSlider(value: 0.75, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let delay = NSSlider(value: 0.5, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let delayLabel = NSTextField(labelWithString: "")
    private let known = NSButton(checkboxWithTitle: "Known formats", target: nil, action: nil)
    private let generic = NSButton(checkboxWithTitle: "Generic secrets", target: nil, action: nil)
    private let personal = NSButton(checkboxWithTitle: "Personal data", target: nil, action: nil)
    private let emails = NSButton(checkboxWithTitle: "Email addresses", target: nil, action: nil)
    private let phones = NSButton(checkboxWithTitle: "Phone numbers", target: nil, action: nil)
    private let ocr = NSButton(checkboxWithTitle: "Use local OCR when app text is unavailable", target: nil, action: nil)
    private let autoArm = NSButton(checkboxWithTitle: "Arm when a supported sharing indicator is detected", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Launch Veil at login", target: nil, action: nil)
    private let modifiers = NSPopUpButton()
    private let presentKey = NSPopUpButton()
    private let peekKey = NSPopUpButton()
    private let accessibility = NSButton()
    private let recording = NSButton()
    private let customRules = NSTextView()
    private let windowRules = NSTextView()
    private let ruleUpdates = NSButton(checkboxWithTitle: "Check for rule pack updates (opt in)", target: nil, action: nil)
    private let rulePackURL = NSTextField(string: "")
    private let hashes = NSPopUpButton()
    private let removeHash = NSButton(title: "Remove selected", target: nil, action: nil)
    private let hashCount = NSTextField(labelWithString: "")
    private let paths = NSTextView()
    private let disabled = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var editedHashes: [String] = []
    private let keyChoices: [(String, UInt32)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
        ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45),
        ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32),
        ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)
    ]
    private let modifierChoices: [(String, UInt32)] = [
        ("Command + Shift", UInt32(cmdKey | shiftKey)),
        ("Control + Option", UInt32(controlKey | optionKey)),
        ("Command + Option", UInt32(cmdKey | optionKey)),
        ("Control + Shift", UInt32(controlKey | shiftKey)),
        ("Command + Control + Shift", UInt32(cmdKey | controlKey | shiftKey))
    ]

    init(store: PreferencesStore, validate: @escaping (Preferences) -> String?, onSave: @escaping () -> Void) {
        self.store = store
        self.validate = validate
        self.onSave = onSave
        super.init()
        build()
    }

    func show() {
        load()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 750),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Veil settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView()
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, view) in [("General", generalTab()), ("Rules", rulesTab()), ("Allowlist", allowlistTab())] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
        }
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        content.addSubview(status)
        content.addSubview(saveButton)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            tabs.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -14),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            saveButton.widthAnchor.constraint(equalToConstant: 90),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            status.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -16),
            status.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
        ])
        window.contentView = content
    }

    private func generalTab() -> NSView {
        mode.addItems(withTitles: ["Screen overlay", "Clean Feed window"])
        modifiers.addItems(withTitles: modifierChoices.map { $0.0 })
        presentKey.addItems(withTitles: keyChoices.map { $0.0 })
        peekKey.addItems(withTitles: keyChoices.map { $0.0 })
        threshold.target = self
        threshold.action = #selector(slidersChanged)
        delay.target = self
        delay.action = #selector(slidersChanged)
        thresholdLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        delayLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        accessibility.target = self
        accessibility.action = #selector(openAccessibility)
        accessibility.bezelStyle = .rounded
        recording.target = self
        recording.action = #selector(openRecording)
        recording.bezelStyle = .rounded
        return column([
            row("Sharing mode", mode),
            note("For single-window sharing, share the Clean Feed window. Screen-sharing apps can omit overlays. Detection is best effort and can miss secrets."),
            row("Mask threshold", horizontal([threshold, thresholdLabel])),
            row("Clean Feed delay", horizontal([delay, delayLabel])),
            row("Detection families", horizontal([known, generic, personal])),
            row("Optional matches", horizontal([emails, phones])),
            ocr, autoArm, login,
            note("Auto-arm is a convenience for supported indicators; check the menu bar before sharing. Starting Veil at login does not start a sharing session."),
            row("Shortcut modifiers", modifiers),
            row("Start / stop presenting", presentKey),
            row("Hold to peek", peekKey),
            note("Shortcut letters use US keyboard positions. Peek temporarily reveals overlays on your screen; Clean Feed stays redacted."),
            row("Accessibility", accessibility),
            row("Screen Recording", recording),
            note("Accessibility reads app text. Screen Recording is needed for OCR and Clean Feed. All detection runs on your Mac; rules and permissions cannot guarantee a leak-free share.")
        ])
    }

    private func rulesTab() -> NSView {
        rulePackURL.placeholderString = "https://example.org/veil-rules.json"
        return column([
            note("Custom rules are JSON arrays of {\"id\":\"my-rule\",\"pattern\":\"regex\",\"score\":0.9}. Scores range from 0 to 1. Use patterns, never paste real keys or credentials."),
            label("Custom detection rules"), editor(customRules, height: 150),
            note("Window rules use {\"bundle\":\"app.bundle.id\",\"pattern\":\"title regex\",\"id\":\"rule-id\"}. A matching bundle OR title masks the visible window."),
            label("Window and title rules"), editor(windowRules, height: 180),
            ruleUpdates, row("Rule pack URL", rulePackURL),
            note("Updates are off by default. Enabling them contacts this HTTPS address for rule definitions; captured text, screenshots and match values are not uploaded.")
        ])
    }

    private func allowlistTab() -> NSView {
        removeHash.target = self
        removeHash.action = #selector(forgetHash)
        removeHash.bezelStyle = .rounded
        hashCount.font = .systemFont(ofSize: 11)
        hashCount.textColor = .secondaryLabelColor
        return column([
            note("Allowed matches are stored as value hashes, never their secret text. Add an exception from a detected match in the menu bar. Only hash prefixes are shown here."),
            row("Allowed match", horizontal([hashes, removeHash])), hashCount,
            label("Allowed file paths — one absolute path per line"), editor(paths, height: 160),
            note("Exact path exceptions suppress matching file-path detections. They do not exempt every secret shown in that file or disable whole-window rules."),
            label("Disabled rule IDs — one per line"), editor(disabled, height: 110),
            note("Allowlist entries reduce protection. Remove an entry to start masking it again. Changes take effect after Save.")
        ])
    }

    private func load() {
        let p = store.current
        mode.selectItem(at: p.mode == "feed" ? 1 : 0)
        threshold.doubleValue = p.threshold
        delay.doubleValue = p.delay
        for (button, enabled) in [(known, p.known), (generic, p.generic), (personal, p.personal),
                                  (emails, p.emails), (phones, p.phones), (ocr, p.ocr),
                                  (autoArm, p.autoArm), (login, p.login), (ruleUpdates, p.ruleUpdates)] {
            button.state = enabled ? .on : .off
        }
        presentKey.selectItem(at: keyChoices.firstIndex(where: { $0.1 == p.presentKey }) ?? 15)
        peekKey.selectItem(at: keyChoices.firstIndex(where: { $0.1 == p.peekKey }) ?? 21)
        modifiers.selectItem(at: modifierChoices.firstIndex(where: { $0.1 == p.modifiers }) ?? 0)
        customRules.string = json(p.customRules)
        windowRules.string = json(p.windowRules)
        rulePackURL.stringValue = p.rulePackURL
        editedHashes = p.allowedHashes
        paths.string = p.allowedPaths.joined(separator: "\n")
        disabled.string = p.disabledRules.joined(separator: "\n")
        status.stringValue = ""
        slidersChanged()
        refreshHashes()
        refreshPermissions()
    }

    @objc private func slidersChanged() {
        thresholdLabel.stringValue = String(format: "%.2f", threshold.doubleValue)
        delayLabel.stringValue = String(format: "%.0f ms", delay.doubleValue * 1000)
    }

    @objc private func forgetHash() {
        let index = hashes.indexOfSelectedItem
        if editedHashes.indices.contains(index) { editedHashes.remove(at: index) }
        refreshHashes()
    }

    private func refreshHashes() {
        hashes.removeAllItems()
        hashes.addItems(withTitles: editedHashes.map { String($0.prefix(12)) + "…" })
        if editedHashes.isEmpty { hashes.addItem(withTitle: "No allowed matches") }
        hashes.isEnabled = !editedHashes.isEmpty
        removeHash.isEnabled = !editedHashes.isEmpty
        hashCount.stringValue = "\(editedHashes.count) allowed match\(editedHashes.count == 1 ? "" : "es")"
    }

    private func refreshPermissions() {
        accessibility.title = AXIsProcessTrusted() ? "Granted · open Settings" : "Not granted · open Settings"
        recording.title = CGPreflightScreenCaptureAccess() ? "Granted · open Settings" : "Not granted · open Settings"
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshPermissions() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func save() {
        var p = store.current
        p.mode = mode.indexOfSelectedItem == 1 ? "feed" : "overlay"
        p.threshold = threshold.doubleValue
        p.delay = delay.doubleValue
        p.known = known.state == .on
        p.generic = generic.state == .on
        p.personal = personal.state == .on
        p.emails = emails.state == .on
        p.phones = phones.state == .on
        p.ocr = ocr.state == .on
        p.autoArm = autoArm.state == .on
        p.login = login.state == .on
        p.ruleUpdates = ruleUpdates.state == .on
        p.presentKey = keyChoices[max(0, presentKey.indexOfSelectedItem)].1
        p.peekKey = keyChoices[max(0, peekKey.indexOfSelectedItem)].1
        p.modifiers = modifierChoices[max(0, modifiers.indexOfSelectedItem)].1
        p.rulePackURL = rulePackURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        p.allowedHashes = editedHashes
        p.allowedPaths = Array(Set(lines(paths.string).map { ($0 as NSString).expandingTildeInPath })).sorted()
        p.disabledRules = lines(disabled.string)
        guard let custom = try? JSONDecoder().decode([CustomRule].self, from: Data(customRules.string.utf8)) else {
            fail("Custom rules must be a JSON array with id, pattern and numeric score fields.")
            return
        }
        guard let windows = try? JSONDecoder().decode([WindowRule].self, from: Data(windowRules.string.utf8)) else {
            fail("Window rules must be a JSON array with bundle, pattern and id fields.")
            return
        }
        p.customRules = custom
        p.windowRules = windows
        if let message = basicValidation(p) ?? validate(p) { fail(message); return }
        saveButton.isEnabled = false
        status.stringValue = "Saving…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { saveButton.isEnabled = true }
            do {
                let service = SMAppService.mainApp
                if p.login && service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                } else if !p.login && (service.status == .enabled || service.status == .requiresApproval) {
                    try await service.unregister()
                }
                guard store.save(p) else { fail("Settings could not be encoded. No changes were saved."); return }
                onSave()
                status.textColor = .secondaryLabelColor
                status.stringValue = p.login && service.status == .requiresApproval
                    ? "Saved. Approve Veil in System Settings → General → Login Items."
                    : "Saved. Changes are active."
                refreshPermissions()
            } catch {
                fail("Login setting could not be changed. Install Veil in Applications and try again. Settings were not saved.")
            }
        }
    }

    private func basicValidation(_ p: Preferences) -> String? {
        if p.presentKey == p.peekKey { return "Choose different keys for presenting and peek." }
        if p.allowedPaths.contains(where: { !$0.hasPrefix("/") }) { return "Each allowed file path must be absolute, beginning with / or ~." }
        if !p.rulePackURL.isEmpty || p.ruleUpdates {
            guard let url = URL(string: p.rulePackURL), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else {
                return "Rule updates need a valid HTTPS URL without embedded credentials."
            }
        }
        var ids = Set<String>()
        for rule in p.customRules {
            if rule.id.isEmpty || !ids.insert(rule.id).inserted { return "Custom rule IDs must be nonempty and unique." }
            if !rule.score.isFinite || !(0...1).contains(rule.score) { return "Custom rule scores must be between 0 and 1." }
            if rule.pattern.isEmpty { return "Custom rule patterns must not be empty." }
        }
        for rule in p.windowRules {
            if rule.id.isEmpty || (rule.bundle.isEmpty && rule.pattern.isEmpty) { return "Each window rule needs an id and a bundle or title pattern." }
            if !rule.pattern.isEmpty && (try? NSRegularExpression(pattern: rule.pattern)) == nil { return "A window title pattern is not a valid regular expression." }
        }
        return nil
    }

    private func fail(_ message: String) {
        status.textColor = .systemRed
        status.stringValue = message
    }

    private func lines(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func row(_ text: String, _ control: NSView) -> NSView {
        let name = NSTextField(labelWithString: text)
        name.font = .systemFont(ofSize: 12)
        name.widthAnchor.constraint(equalToConstant: 162).isActive = true
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        return horizontal([name, control])
    }

    private func editor(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        text.frame = NSRect(x: 0, y: 0, width: 670, height: height)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 7, height: 7)
        scroll.documentView = text
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func column(_ views: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let content = SettingsContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.documentView = content
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }
}
