import AppKit
import ApplicationServices

final class Onboarding {
    private var window: NSWindow?
    private var testWindow: NSWindow?
    private static let samples = """
    Synthetic Veil examples — not real personal data
    AWS example: AKIAIOSFODNN7EXAMPLE
    SSN example: 123-45-6789
    SSN with en dashes: 123–45–6789
    Test card: 4111111111111111
    """
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
            let test = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 590), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            test.title = "Veil Test"
            test.isReleasedWhenClosed = false
            test.minSize = NSSize(width: 540, height: 420)
            let content = NSView()
            let title = NSTextField(labelWithString: "Scroll through harmless test examples")
            title.font = .systemFont(ofSize: 22, weight: .semibold)
            let instructions = NSTextField(wrappingLabelWithString: "Scroll slowly, then quickly. Examples repeat at the start, middle and end in 14 and 18 pt text. Copy them into Docs or chat to compare. In Clean Feed, check the Veil Feed window.")
            instructions.font = .systemFont(ofSize: 13)
            instructions.textColor = .secondaryLabelColor
            let copy = button("Copy synthetic samples", #selector(copySamples))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 420))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = false
            scroll.borderType = .bezelBorder
            let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 420))
            document.isEditable = false
            document.isSelectable = true
            document.isVerticallyResizable = true
            document.isHorizontallyResizable = false
            document.autoresizingMask = [.width]
            document.minSize = NSSize(width: 0, height: 420)
            document.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            document.textContainerInset = NSSize(width: 18, height: 18)
            document.textContainer?.containerSize = NSSize(width: 614, height: CGFloat.greatestFiniteMagnitude)
            document.textContainer?.widthTracksTextView = true
            document.textStorage?.setAttributedString(Self.scrollSamples())
            scroll.documentView = document
            let views: [NSView] = [title, instructions, copy, scroll]
            for view in views {
                view.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(view)
            }
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                instructions.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                instructions.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                instructions.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
                copy.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                copy.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 12),
                scroll.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 16),
                scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
            ])
            test.contentView = content
            document.sizeToFit()
            document.scrollToBeginningOfDocument(nil)
            test.center()
            testWindow = test
        }
        testWindow?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "setupSeen")
        runTest?()
    }
    @objc private func copySamples() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.samples, forType: .string)
    }
    private static func scrollSamples() -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        func append(_ text: String, size: CGFloat, bold: Bool = false) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph
            ]))
        }
        for section in 0..<3 {
            let size: CGFloat = section == 1 ? 18 : 14
            append(["Start · 14 pt", "Middle · 18 pt", "End · 14 pt"][section], size: 18, bold: true)
            append(samples, size: size)
            if section < 2 {
                for row in 1...18 {
                    append("Practice row \(section * 18 + row): a quiet page with ordinary notes.", size: 14)
                }
            }
        }
        return result
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
