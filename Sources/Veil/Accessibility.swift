import AppKit
import ApplicationServices

private func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func axRect(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

final class AccessibilityReader {
    var onMasks: (([Mask]) -> Void)?
    var onInvalidation: (() -> Void)?
    private let queue = DispatchQueue(label: "veil.accessibility", qos: .userInteractive)
    private var busy = false
    private var generation = 0
    private var observers: [pid_t: AXObserver] = [:]
    private var previousAreas: [String: (Int, CGRect, TimeInterval)] = [:]
    func stop() {
        generation += 1
        observers.values.forEach { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource($0), .commonModes) }
        observers.removeAll()
        queue.async { self.previousAreas.removeAll() }
    }
    func scan(windows: [ScreenWindow], engine: CoreEngine) {
        guard !busy, AXIsProcessTrusted() else { return }
        busy = true
        let revision = generation
        let pids = Set(windows.filter { $0.layer == 0 }.map(\.pid))
        for pid in Array(observers.keys) where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
        queue.async {
            var masks: [Mask] = []
            let deadline = ProcessInfo.processInfo.systemUptime + 0.18
            for pid in pids {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.04)
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                guard let axWindows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for axWindow in axWindows {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    guard let rect = axRect(axWindow), let window = windows.first(where: { $0.pid == pid && abs($0.bounds.minX - rect.minX) < 3 && abs($0.bounds.minY - rect.minY) < 3 }),
                          !window.visibleParts(of: rect, in: windows).isEmpty else { continue }
                    var pending = [axWindow]
                    var count = 0
                    while let element = pending.popLast(), count < 450, ProcessInfo.processInfo.systemUptime < deadline {
                        count += 1
                        if let frame = axRect(element), frame.intersects(window.bounds), !window.visibleParts(of: frame, in: windows).isEmpty {
                            let text = axValue(element, kAXValueAttribute) as? String ?? axValue(element, kAXTitleAttribute) as? String ?? ""
                            if !text.isEmpty, text.utf8.count < 262_144 {
                                let hits: [EngineMatch]
                                do { hits = try engine.scan(text, title: window.title, path: Self.documentPath(axWindow)) }
                                catch {
                                    masks.append(Mask(rect: window.bounds, rule: "detector-error", app: window.app, windowID: window.id))
                                    continue
                                }
                                for hit in hits {
                                    guard let range = Self.stringRange(hit.start..<hit.end, in: text) else { continue }
                                    let nsRange = NSRange(range, in: text)
                                    var axRange = CFRange(location: nsRange.location, length: nsRange.length)
                                    var result: CFTypeRef?
                                    var bounds = frame
                                    if let rangeValue = AXValueCreate(.cfRange, &axRange),
                                       AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
                                       let result, CFGetTypeID(result) == AXValueGetTypeID() {
                                        _ = AXValueGetValue(result as! AXValue, .cgRect, &bounds)
                                    }
                                    bounds = bounds.insetBy(dx: -4, dy: -4).intersection(frame).intersection(window.bounds)
                                    if !bounds.isEmpty && !bounds.isNull {
                                        masks += window.visibleParts(of: bounds, in: windows).map {
                                            Mask(rect: $0, rule: hit.rule, app: window.app, hash: hit.hash, windowID: window.id)
                                        }
                                    }
                                }
                            }
                        }
                        if let children = axValue(element, kAXVisibleChildrenAttribute) as? [AXUIElement] ?? axValue(element, kAXChildrenAttribute) as? [AXUIElement] {
                            pending.append(contentsOf: children.prefix(max(0, 450 - count - pending.count)))
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                guard self.generation == revision else { return }
                self.installObservers(pids)
                self.onMasks?(masks)
            }
        }
    }
    private func installObservers(_ pids: Set<pid_t>) {
        for pid in pids where observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<AccessibilityReader>.fromOpaque(context).takeUnretainedValue().onInvalidation?()
            }, &observer) == .success, let observer else { continue }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.02)
            AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = observer
        }
    }
    static func stringRange(_ bytes: Range<Int>, in text: String) -> Range<String.Index>? {
        guard bytes.lowerBound >= 0, bytes.upperBound <= text.utf8.count,
              let start = text.utf8.index(text.utf8.startIndex, offsetBy: bytes.lowerBound).samePosition(in: text),
              let end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes.upperBound).samePosition(in: text) else { return nil }
        return start..<end
    }
    private static func documentPath(_ window: AXUIElement) -> String {
        guard let raw = axValue(window, kAXDocumentAttribute) as? String else { return "" }
        return URL(string: raw)?.path ?? raw
    }
}
