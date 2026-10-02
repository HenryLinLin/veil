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
    guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
          [p.x, p.y, s.width, s.height].allSatisfy({ $0.isFinite }), s.width > 0, s.height > 0 else { return nil }
    return CGRect(origin: p, size: s)
}

private func axChildren(_ element: AXUIElement) -> (elements: [AXUIElement], complete: Bool) {
    var value: CFTypeRef?
    let visible = AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &value)
    if visible == .success, let children = value as? [AXUIElement] { return (children, true) }
    value = nil
    let all = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    if all == .success, let children = value as? [AXUIElement] { return (children, true) }
    let leafErrors: [AXError] = [.attributeUnsupported, .noValue, .notImplemented]
    return ([], leafErrors.contains(visible) && leafErrors.contains(all))
}

private final class AXCallbackContext {
    weak var owner: AccessibilityReader?
    let generation: Int
    let pid: pid_t
    private let lock = NSLock()
    private var contentWindows: [UInt: (CGWindowID, Set<String>)] = [:]
    func registerContent(_ element: AXUIElement, windowID: CGWindowID, notification: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = CFHash(element)
        guard contentWindows[key] != nil || contentWindows.count < 256 else { return }
        var names = contentWindows[key]?.1 ?? []
        names.insert(notification)
        contentWindows[key] = (windowID, names)
    }
    func contentWindow(_ element: AXUIElement, notification: String) -> CGWindowID? {
        lock.lock()
        defer { lock.unlock() }
        guard let (window, names) = contentWindows[CFHash(element)], names.contains(notification) else { return nil }
        return window
    }
    init(_ owner: AccessibilityReader, generation: Int, pid: pid_t) {
        self.owner = owner
        self.generation = generation
        self.pid = pid
    }
}

private final class AXWatch {
    let observer: AXObserver
    let context: AXCallbackContext
    var registered: Set<String> = []
    init(observer: AXObserver, context: AXCallbackContext) {
        self.observer = observer
        self.context = context
    }
}

final class AccessibilityReader {
    var onMasks: (([Mask], TimeInterval) -> Void)?
    var onInvalidation: (() -> Void)?
    var onContentInvalidation: ((Set<CGWindowID>) -> Void)?
    var onPaths: (([CGWindowID: String]) -> Void)?
    var onScanCompleted: ((Set<CGWindowID>, TimeInterval) -> Void)?
    private let queue = DispatchQueue(label: "veil.accessibility", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    var isScanning: Bool { busy }
    private var generation = 0
    private var observers: [pid_t: AXWatch] = [:]
    private var invalidation: DispatchWorkItem?
    private var cachedMasks: [AreaID: [Mask]] = [:]
    private var cachedMaskCount = 0
    private var scanOffset = 0
    private var priorityPID: pid_t?

    func prioritize(pid: pid_t) {
        precondition(Thread.isMainThread)
        priorityPID = pid
        onInvalidation?()
    }

    private struct AreaID: Hashable {
        let window: CGWindowID
        let element: UInt
    }
    private struct TextSlice {
        let text: String
        let offset: Int
        let visibleRange: CFRange?
    }
    private struct WatchTarget {
        let pid: pid_t
        let element: AXUIElement
        let names: [String]
        var windowID: CGWindowID? = nil
        var contentNames: Set<String> = []
    }

    func stop() {
        precondition(Thread.isMainThread)
        lock.lock()
        generation += 1
        lock.unlock()
        invalidation?.cancel()
        invalidation = nil
        priorityPID = nil
        observers.values.forEach { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource($0.observer), .commonModes) }
        observers.removeAll()
        queue.async { [weak self] in
            self?.cachedMasks.removeAll()
            self?.cachedMaskCount = 0
        }
    }

    func invalidateContent(windowIDs: Set<CGWindowID>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cachedMasks = self.cachedMasks.filter { !windowIDs.contains($0.key.window) }
            self.cachedMaskCount = self.cachedMasks.values.reduce(0) { $0 + $1.count }
        }
    }

    func scan(windows: [ScreenWindow], engine: CoreEngine) {
        precondition(Thread.isMainThread)
        guard !busy, AXIsProcessTrusted() else { return }
        busy = true
        let revision = currentGeneration()
        let pids = Set(windows.filter { $0.layer == 0 }.map(\.pid))
        for pid in Array(observers.keys) where !pids.contains(pid) {
            if let watch = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
            }
        }
        let watched = observers
        let order = Array(pids).sorted()
        let offset = order.isEmpty ? 0 : scanOffset % order.count
        scanOffset += 1
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let preferred = priorityPID.flatMap { pids.contains($0) ? $0 : nil }
            ?? frontmost.flatMap { pids.contains($0) ? $0 : nil }
            ?? windows.first(where: { $0.layer == 0 })?.pid
        let rotated = (preferred.map { [$0] } ?? [])
            + (Array(order.dropFirst(offset)) + Array(order.prefix(offset))).filter { $0 != preferred }
        priorityPID = nil
        queue.async { [weak self] in
            guard let self else { return }
            var paths: [CGWindowID: String] = [:]
            var targets: [WatchTarget] = []
            var completedWindows: Set<CGWindowID> = []
            let startedAt = ProcessInfo.processInfo.systemUptime
            let deadline = startedAt + 0.18
            var remaining = 450
            for pid in rotated {
                guard self.currentGeneration() == revision,
                      ProcessInfo.processInfo.systemUptime < deadline, remaining > 0 else { break }
                let appDeadline = pid == preferred && rotated.count > 1 ? min(deadline, startedAt + 0.11) : deadline
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.025)
                targets.append(WatchTarget(pid: pid, element: app, names: [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification]))
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                guard let axWindows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for axWindow in axWindows.prefix(32) {
                    guard self.currentGeneration() == revision,
                          ProcessInfo.processInfo.systemUptime < appDeadline, remaining > 0 else { break }
                    remaining -= 1
                    guard let rect = axRect(axWindow), let window = windows.first(where: {
                        $0.pid == pid && abs($0.bounds.minX - rect.minX) < 3 && abs($0.bounds.minY - rect.minY) < 3
                            && abs($0.bounds.width - rect.width) < 6 && abs($0.bounds.height - rect.height) < 6
                    }), !window.visibleParts(of: rect, in: windows).isEmpty else { continue }
                    if targets.count < 32 {
                        targets.append(WatchTarget(pid: pid, element: axWindow, names: [kAXMovedNotification, kAXResizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXLayoutChangedNotification],
                                                   windowID: window.id, contentNames: [kAXResizedNotification, kAXWindowResizedNotification, kAXLayoutChangedNotification]))
                    }
                    let document = Self.documentPath(axWindow)
                    paths[window.id] = document
                    var pending = [axWindow]
                    var seenAreas: Set<AreaID> = []
                    var traversalComplete = true
                    var readText = false
                    while let element = pending.popLast(), remaining > 0,
                          self.currentGeneration() == revision, ProcessInfo.processInfo.systemUptime < appDeadline {
                        remaining -= 1
                        seenAreas.insert(AreaID(window: window.id, element: CFHash(element)))
                        if let frame = axRect(element), frame.intersects(window.bounds),
                           !window.visibleParts(of: frame, in: windows).isEmpty {
                            let key = AreaID(window: window.id, element: CFHash(element))
                            var elementMasks: [Mask] = []
                            let role = axValue(element, kAXRoleAttribute) as? String ?? ""
                            if (role == kAXScrollAreaRole || role == kAXScrollBarRole), targets.count < 32 {
                                targets.append(WatchTarget(pid: pid, element: element,
                                                           names: [kAXValueChangedNotification, kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification],
                                                           windowID: window.id, contentNames: [kAXValueChangedNotification, kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification]))
                            }
                            if let slice = Self.visibleText(element) {
                                if !slice.text.isEmpty || role == kAXTextAreaRole || role == kAXTextFieldRole { readText = true }
                                let textArea = role == kAXTextAreaRole || role == kAXTextFieldRole || slice.visibleRange != nil
                                let trackLayout = textArea || role == kAXStaticTextRole
                                if trackLayout, targets.count < 32 {
                                    targets.append(WatchTarget(pid: pid, element: element, names: [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXLayoutChangedNotification, kAXMovedNotification],
                                                               windowID: window.id, contentNames: [kAXLayoutChangedNotification, kAXMovedNotification]))
                                }
                                let hits: [EngineMatch]
                                do {
                                    if slice.text.isEmpty { hits = [] }
                                    else { hits = try engine.scan(slice.text, title: window.title, path: document) }
                                }
                                catch {
                                    traversalComplete = false
                                    hits = []
                                }
                                for hit in hits {
                                    guard let range = Self.stringRange(hit.start..<hit.end, in: slice.text) else { continue }
                                    let local = NSRange(range, in: slice.text)
                                    var axRange = CFRange(location: local.location + slice.offset, length: local.length)
                                    var result: CFTypeRef?
                                    var bounds: CGRect?
                                    if hit.rule == "private-key" {
                                        bounds = window.bounds
                                    } else if let value = AXValueCreate(.cfRange, &axRange),
                                              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &result) == .success,
                                              let result, CFGetTypeID(result) == AXValueGetTypeID() {
                                        var exact = CGRect.zero
                                        if AXValueGetValue(result as! AXValue, .cgRect, &exact) {
                                            bounds = Self.rangeTextBounds(exact, text: String(slice.text[range]))
                                        }
                                    }
                                    if bounds == nil {
                                        bounds = Self.staticTextBounds(slice.text, match: local, role: role, frame: frame)
                                    }
                                    guard let bounds else { continue }
                                    let limit = hit.rule == "private-key" ? window.bounds : frame.intersection(window.bounds)
                                    let covered = bounds.insetBy(dx: -4, dy: -4).intersection(limit)
                                    if !covered.isEmpty && !covered.isNull {
                                        elementMasks += window.visibleParts(of: covered, in: windows).map {
                                            Mask(rect: $0, rule: hit.rule, app: window.app, hash: hit.hash, windowID: window.id, anchor: window.bounds)
                                        }
                                    }
                                }
                                self.storeMasks(elementMasks, for: key)
                            } else {
                                if role == kAXStaticTextRole || role == kAXTextAreaRole || role == kAXTextFieldRole {
                                    traversalComplete = false
                                }
                                self.storeMasks([], for: key)
                            }
                        }
                        let children = axChildren(element)
                        let capacity = max(0, remaining - pending.count)
                        if !children.complete || children.elements.count > capacity { traversalComplete = false }
                        pending.append(contentsOf: children.elements.prefix(capacity))
                    }
                    if pending.isEmpty, traversalComplete, remaining > 0, ProcessInfo.processInfo.systemUptime < appDeadline,
                       self.currentGeneration() == revision {
                        self.cachedMasks = self.cachedMasks.filter { $0.key.window != window.id || seenAreas.contains($0.key) }
                        self.cachedMaskCount = self.cachedMasks.values.reduce(0) { $0 + $1.count }
                        if readText { completedWindows.insert(window.id) }
                    }
                }
            }
            let ids = Set(windows.map(\.id))
            self.cachedMasks = self.cachedMasks.filter { ids.contains($0.key.window) }
            self.cachedMaskCount = self.cachedMasks.values.reduce(0) { $0 + $1.count }
            let masks = self.visibleMasks(windows: windows)
            let installed = self.installObservers(targets, existing: watched, generation: revision)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.currentGeneration() == revision else { return }
                for (pid, watch) in installed where self.observers[pid] == nil {
                    self.observers[pid] = watch
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
                }
                self.onMasks?(masks, startedAt)
                self.onPaths?(paths)
                self.onScanCompleted?(completedWindows, startedAt)
            }
        }
    }

    private func storeMasks(_ masks: [Mask], for key: AreaID) {
        let previousCount = cachedMasks[key]?.count ?? 0
        let capacity = max(0, 4096 - (cachedMaskCount - previousCount))
        let kept = Array(masks.prefix(capacity))
        if kept.isEmpty { cachedMasks.removeValue(forKey: key) }
        else { cachedMasks[key] = kept }
        cachedMaskCount += kept.count - previousCount
    }

    private func visibleMasks(windows: [ScreenWindow]) -> [Mask] {
        var result: [Mask] = []
        for masks in cachedMasks.values {
            for original in masks {
                guard let window = windows.first(where: { $0.id == original.windowID }) else { continue }
                var mask = original
                if let anchor = mask.anchor {
                    if anchor.size != window.bounds.size {
                        guard mask.rule == "private-key" else { continue }
                        mask.rect = window.bounds
                    } else {
                        mask.rect = mask.rect.offsetBy(dx: window.bounds.minX - anchor.minX, dy: window.bounds.minY - anchor.minY)
                    }
                }
                mask.anchor = window.bounds
                result += window.visibleParts(of: mask.rect, in: windows).map { rect in
                    var part = mask
                    part.rect = rect
                    return part
                }
            }
        }
        return result
    }

    private func installObservers(_ targets: [WatchTarget], existing: [pid_t: AXWatch], generation: Int) -> [pid_t: AXWatch] {
        var watches = existing
        var installed: [pid_t: AXWatch] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.06
        var attempts = 0
        for target in targets {
            guard currentGeneration() == generation, ProcessInfo.processInfo.systemUptime < deadline else { break }
            if watches[target.pid] == nil {
                var observer: AXObserver?
                guard AXObserverCreate(target.pid, { _, element, notification, context in
                    guard let context else { return }
                    let callback = Unmanaged<AXCallbackContext>.fromOpaque(context).takeUnretainedValue()
                    let windowID = callback.contentWindow(element, notification: notification as String)
                    callback.owner?.enqueueInvalidation(generation: callback.generation, pid: callback.pid, contentWindow: windowID)
                }, &observer) == .success, let observer else { continue }
                let watch = AXWatch(observer: observer, context: AXCallbackContext(self, generation: generation, pid: target.pid))
                watches[target.pid] = watch
                installed[target.pid] = watch
            }
            guard let watch = watches[target.pid], watch.registered.count < 256 else { continue }
            AXUIElementSetMessagingTimeout(target.element, 0.015)
            for name in target.names {
                guard currentGeneration() == generation, ProcessInfo.processInfo.systemUptime < deadline, attempts < 24 else { break }
                let key = "\(CFHash(target.element)):\(name)"
                if let windowID = target.windowID, target.contentNames.contains(name) {
                    watch.context.registerContent(target.element, windowID: windowID, notification: name)
                }
                guard !watch.registered.contains(key) else { continue }
                attempts += 1
                let status = AXObserverAddNotification(watch.observer, target.element, name as CFString,
                                                       Unmanaged.passUnretained(watch.context).toOpaque())
                if status == .success || status == .notificationAlreadyRegistered || status == .notificationUnsupported {
                    watch.registered.insert(key)
                }
            }
        }
        return installed
    }

    fileprivate func enqueueInvalidation(generation: Int, pid: pid_t, contentWindow: CGWindowID?) {
        precondition(Thread.isMainThread)
        guard currentGeneration() == generation else { return }
        priorityPID = pid
        if let contentWindow { onContentInvalidation?([contentWindow]) }
        guard invalidation == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.invalidation = nil
            guard self.currentGeneration() == generation else { return }
            self.onInvalidation?()
        }
        invalidation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    static func rangeTextBounds(_ rect: CGRect, text: String) -> CGRect? {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: CharacterSet.newlines.contains),
              !rect.isEmpty, !rect.isNull, rect.height <= 64,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              rect.width <= max(24, CGFloat(text.count) * rect.height * 1.2) else { return nil }
        return rect
    }

    static func staticTextBounds(_ text: String, match: NSRange, role: String, frame: CGRect) -> CGRect? {
        guard role == kAXStaticTextRole, let range = Range(match, in: text),
              !text.unicodeScalars.contains(where: CharacterSet.newlines.contains),
              !frame.isEmpty, !frame.isNull, frame.height <= 48,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }) else { return nil }
        let line = text.trimmingCharacters(in: .whitespaces)
        let hit = text[range].trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, Double(hit.utf16.count) >= Double(line.utf16.count) * 0.75,
              frame.width <= CGFloat(line.count) * frame.height else { return nil }
        return frame
    }

    static func stringRange(_ bytes: Range<Int>, in text: String) -> Range<String.Index>? {
        guard bytes.lowerBound >= 0, bytes.upperBound <= text.utf8.count,
              let start = text.utf8.index(text.utf8.startIndex, offsetBy: bytes.lowerBound).samePosition(in: text),
              let end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes.upperBound).samePosition(in: text) else { return nil }
        return start..<end
    }

    static func slice(_ text: String, visibleRange: CFRange) -> String? {
        guard visibleRange.location >= 0, visibleRange.length >= 0,
              visibleRange.location <= text.utf16.count,
              visibleRange.length <= text.utf16.count - visibleRange.location,
              let range = Range(NSRange(location: visibleRange.location, length: visibleRange.length), in: text) else { return nil }
        return String(text[range])
    }

    private static func visibleText(_ element: AXUIElement) -> TextSlice? {
        var visible: CFRange?
        if let value = axValue(element, kAXVisibleCharacterRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0, range.length <= 65_536 {
                visible = range
                if range.length == 0 { return TextSlice(text: "", offset: range.location, visibleRange: range) }
                var result: CFTypeRef?
                if let parameter = AXValueCreate(.cfRange, &range),
                   AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
                   let text = result as? String, text.utf8.count <= 262_144 {
                    return TextSlice(text: text, offset: range.location, visibleRange: range)
                }
            }
        }
        if let count = axValue(element, kAXNumberOfCharactersAttribute) as? NSNumber, count.intValue > 262_144 { return nil }
        guard let text = axValue(element, kAXValueAttribute) as? String ?? axValue(element, kAXTitleAttribute) as? String,
              text.utf8.count <= 262_144 else { return nil }
        if let visible {
            guard let clipped = slice(text, visibleRange: visible) else { return nil }
            return TextSlice(text: clipped, offset: visible.location, visibleRange: visible)
        }
        return TextSlice(text: text, offset: 0, visibleRange: nil)
    }

    private static func documentPath(_ window: AXUIElement) -> String {
        guard let raw = axValue(window, kAXDocumentAttribute) as? String else { return "" }
        return URL(string: raw)?.path ?? raw
    }

    deinit {
        invalidation?.cancel()
        let watches = Array(observers.values)
        let remove = {
            for watch in watches { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes) }
        }
        if Thread.isMainThread { remove() } else { DispatchQueue.main.async(execute: remove) }
    }
}
