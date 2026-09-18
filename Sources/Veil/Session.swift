import AppKit

final class SessionSummary {
    private var events: [String: Set<String>] = [:]
    private var began = Date()
    private var seenCount = 0
    private var window: NSWindow?
    func start() { events.removeAll(); seenCount = 0; began = Date() }
    func record(_ masks: [Mask]) {
        for mask in masks {
            let key = mask.rule + "\t" + mask.app
            if seenCount < 20_000 && (events.count < 500 || events[key] != nil) {
                if events[key, default: []].insert(mask.hash.isEmpty ? String(mask.windowID) : mask.hash).inserted { seenCount += 1 }
            }
        }
    }
    func show() {
        let rows = events.sorted { $0.key < $1.key }.map { key, values -> String in
            let fields = key.components(separatedBy: "\t")
            return "\(fields[0])  ·  \(fields[1])  ·  \(values.count) protected item(s)\n\(Self.guidance(fields[0]))"
        }
        let body = "Session started \(began.formatted(date: .abbreviated, time: .shortened))\n\n" +
            (rows.isEmpty ? "No recognised secrets were detected." : rows.joined(separator: "\n\n")) +
            "\n\nOnly rule and app counts are kept in memory. No text, images or recordings are saved. Detection is a safety net; rotate any credential you think was exposed."
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Veil · Session summary"
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 24, height: 24)
        text.string = body
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        panel.contentView = scroll
        panel.center()
        window?.close()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        events.removeAll()
    }
    static func guidance(_ rule: String) -> String {
        if rule.contains("aws") { return "Revoke the exposed access key in IAM and issue a replacement." }
        if rule.contains("github") { return "Revoke the token in GitHub developer settings and replace it wherever used." }
        if rule.contains("stripe") { return "Roll the exposed live key from your Stripe dashboard." }
        if rule.contains("slack") { return "Revoke the Slack token and reinstall or reauthorize the integration." }
        if rule.contains("private") { return "Replace the key pair and remove the old public key from authorized services." }
        if rule.contains("openai") || rule.contains("anthropic") || rule.contains("google") { return "Revoke this API credential in its provider console and create a replacement." }
        if rule.contains("database") { return "Change the database password and update dependent services." }
        return "If this information was exposed, review access and replace any reusable credential." 
    }
}
