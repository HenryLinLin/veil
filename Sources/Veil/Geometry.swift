import AppKit

func subtract(_ rect: CGRect, _ cover: CGRect) -> [CGRect] {
    let cut = rect.intersection(cover)
    guard !cut.isNull, !cut.isEmpty else { return [rect] }
    return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)]
        .filter { $0.width > 0 && $0.height > 0 }
}

struct ScreenWindow {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let bounds: CGRect
    let layer: Int

    static func visible() -> [ScreenWindow] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let dict = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width > 1, bounds.height > 1,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return ScreenWindow(id: id, pid: pid,
                app: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown",
                title: row[kCGWindowName as String] as? String ?? "", bounds: bounds,
                layer: row[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    func visibleParts(of rect: CGRect, in windows: [ScreenWindow]) -> [CGRect] {
        var parts = [rect.intersection(bounds)].filter { !$0.isNull && !$0.isEmpty }
        for window in windows {
            if window.id == id { break }
            guard window.layer == 0 else { continue }
            parts = parts.flatMap { subtract($0, window.bounds) }
        }
        return parts
    }
}

struct WindowRule: Codable {
    var bundle: String
    var pattern: String
    var id: String
    func matches(_ window: ScreenWindow) -> Bool {
        if !bundle.isEmpty && window.app == bundle { return true }
        return !pattern.isEmpty && window.title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static let defaults: [WindowRule] = [
        WindowRule(bundle: "com.1password.1password", pattern: "", id: "password-manager"),
        WindowRule(bundle: "com.agilebits.onepassword7", pattern: "", id: "password-manager"),
        WindowRule(bundle: "com.bitwarden.desktop", pattern: "", id: "password-manager"),
        WindowRule(bundle: "com.apple.keychainaccess", pattern: "", id: "password-manager"),
        WindowRule(bundle: "com.apple.Passwords", pattern: "", id: "password-manager"),
        WindowRule(bundle: "com.apple.MobileSMS", pattern: "", id: "private-messages"),
        WindowRule(bundle: "net.whatsapp.WhatsApp", pattern: "", id: "private-messages"),
        WindowRule(bundle: "", pattern: #"(^|[/\s])\.env([.\s—-]|$)|\.pem(\s|$)|id_rsa|credentials|secrets\."#, id: "sensitive-file")
    ]
}

struct Mask {
    var rect: CGRect
    var rule: String
    var app: String
    var hash: String = ""
    var windowID: CGWindowID = 0
    var anchor: CGRect? = nil
}

struct WindowSignature: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let layer: Int
    let title: Int
    static func current() -> [WindowSignature] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let dict = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary), rect.width > 1, rect.height > 1,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return WindowSignature(id: id, pid: pid, bounds: rect, layer: row[kCGWindowLayer as String] as? Int ?? 0,
                                   title: (row[kCGWindowName as String] as? String ?? "").hashValue)
        }
    }
}
