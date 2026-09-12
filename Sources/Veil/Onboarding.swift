import AppKit
import ApplicationServices

final class Onboarding {
    private var window: NSWindow?
    private var testWindow: NSWindow?
    var runTest: (() -> Void)?
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Veil"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 28, right: 30)
        let heading = NSTextField(labelWithString: "Share your work. Keep your secrets.")
        heading.font = .systemFont(ofSize: 25, weight: .semibold)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(label("Veil covers sensitive windows and recognised secrets while you present. Everything is processed on this Mac."))
        stack.addArrangedSubview(button("1. Allow Accessibility", #selector(accessibility)))
        stack.addArrangedSubview(label("Reads visible text and tracks other apps’ windows."))
        stack.addArrangedSubview(button("2. Allow Screen Recording", #selector(recording)))
        stack.addArrangedSubview(label("Enables window titles, OCR and Clean Feed. After granting access, quit and reopen Veil if macOS asks."))
        stack.addArrangedSubview(button("3. Open the test window", #selector(test)))
        stack.addArrangedSubview(label("Overlay works with a full-display share. For a single-window share, choose Clean Feed and share the Veil Feed window. Overlay has detection latency; small or unreadable text can escape detection."))
        window.contentView = stack
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func accessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func recording() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func test() {
        if testWindow == nil {
            let test = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 230), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            test.title = "Veil Test"
            test.isReleasedWhenClosed = false
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 20
            stack.edgeInsets = NSEdgeInsets(top: 28, left: 25, bottom: 28, right: 25)
            let title = NSTextField(labelWithString: "A harmless key. A real mask.")
            title.font = .systemFont(ofSize: 23, weight: .semibold)
            stack.addArrangedSubview(title)
            let key = NSTextField(labelWithString: "AKIAIOSFODNN7EXAMPLE")
            key.font = .monospacedSystemFont(ofSize: 30, weight: .medium)
            stack.addArrangedSubview(key)
            stack.addArrangedSubview(label("AWS’s documented example key should be covered. In Clean Feed, check the Veil Feed window instead."))
            test.contentView = stack
            test.center()
            testWindow = test
        }
        testWindow?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "setupSeen")
        runTest?()
    }
    private func label(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 515
        return field
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
}
