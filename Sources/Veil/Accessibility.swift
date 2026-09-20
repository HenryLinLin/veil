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

private final class AXCallbackContext {
    weak var owner: AccessibilityReader?
    let generation: Int
    init(_ owner: AccessibilityReader, generation: Int) {
        self.owner = owner
        self.generation = generation
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
    var onMasks: (([Mask]) -> Void)?
    var onInvalidation: (() -> Void)?
    var onPaths: (([CGWindowID: String]) -> Void)?
    private let queue = DispatchQueue(label: "veil.accessibility", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    var isScanning: Bool { busy }
    private var generation = 0
    private var observers: [pid_t: AXWatch] = [:]
    private var invalidation: DispatchWorkItem?
    private var stabilityCheck: DispatchWorkItem?
    private var previousAreas: [AreaID: AreaState] = [:]
    private var cachedMasks: [AreaID: [Mask]] = [:]
    private var cachedMaskCount = 0
    private var overflowWindows: Set<CGWindowID> = []
    private var scanOffset = 0

    private struct AreaID: Hashable {
        let window: CGWindowID
        let element: UInt
    }
    private struct AreaState {
        let signature: Int
        let changedAt: TimeInterval
        let seenAt: TimeInterval
        let hadSecret: Bool
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
    }

    func stop() {
        precondition(Thread.isMainThread)
        lock.lock()
        generation += 1
        lock.unlock()
        invalidation?.cancel()
        invalidation = nil
        stabilityCheck?.cancel()
        stabilityCheck = nil
        observers.values.forEach { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource($0.observer), .commonModes) }
        observers.removeAll()
        queue.async { [weak self] in
            self?.previousAreas.removeAll()
            self?.cachedMasks.removeAll()
            self?.cachedMaskCount = 0
            self?.overflowWindows.removeAll()
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
        let rotated = Array(order.dropFirst(offset)) + Array(order.prefix(offset))
        queue.async { [weak self] in
            guard let self else { return }
            var paths: [CGWindowID: String] = [:]
            var targets: [WatchTarget] = []
            var unstable = false
            let deadline = ProcessInfo.processInfo.systemUptime + 0.18
            var remaining = 450
            for pid in rotated {
                guard self.currentGeneration() == revision,
                      ProcessInfo.processInfo.systemUptime < deadline, remaining > 0 else { break }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.025)
                targets.append(WatchTarget(pid: pid, element: app, names: [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification]))
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                guard let axWindows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for axWindow in axWindows.prefix(32) {
                    guard self.currentGeneration() == revision,
                          ProcessInfo.processInfo.systemUptime < deadline, remaining > 0 else { break }
                    remaining -= 1
                    guard let rect = axRect(axWindow), let window = windows.first(where: {
                        $0.pid == pid && abs($0.bounds.minX - rect.minX) < 3 && abs($0.bounds.minY - rect.minY) < 3
                            && abs($0.bounds.width - rect.width) < 6 && abs($0.bounds.height - rect.height) < 6
                    }), !window.visibleParts(of: rect, in: windows).isEmpty else { continue }
                    if targets.count < 32 {
                        targets.append(WatchTarget(pid: pid, element: axWindow, names: [kAXMovedNotification, kAXResizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXLayoutChangedNotification]))
                    }
                    let document = Self.documentPath(axWindow)
                    paths[window.id] = document
                    var pending = [axWindow]
                    var seenAreas: Set<AreaID> = []
                    while let element = pending.popLast(), remaining > 0,
                          self.currentGeneration() == revision, ProcessInfo.processInfo.systemUptime < deadline {
                        remaining -= 1
                        seenAreas.insert(AreaID(window: window.id, element: CFHash(element)))
                        if let frame = axRect(element), frame.intersects(window.bounds),
                           !window.visibleParts(of: frame, in: windows).isEmpty {
                            let key = AreaID(window: window.id, element: CFHash(element))
                            var elementMasks: [Mask] = []
                            let role = axValue(element, kAXRoleAttribute) as? String ?? ""
                            if let slice = Self.visibleText(element) {
                                let textArea = role == kAXTextAreaRole || role == kAXTextFieldRole || slice.visibleRange != nil
                                if textArea, targets.count < 32 {
                                    targets.append(WatchTarget(pid: pid, element: element, names: [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXLayoutChangedNotification]))
                                }
                                let hits: [EngineMatch]
                                do { hits = try engine.scan(slice.text, title: window.title, path: document) }
                                catch {
                                    self.storeMasks([Mask(rect: window.bounds, rule: "detector-error", app: window.app,
                                                          windowID: window.id, anchor: window.bounds)], for: key)
                                    continue
                                }
                                if textArea {
                                    let now = ProcessInfo.processInfo.systemUptime
                                    var fingerprint = Hasher()
                                    fingerprint.combine(slice.text)
                                    fingerprint.combine(slice.visibleRange?.location ?? -1)
                                    fingerprint.combine(slice.visibleRange?.length ?? -1)
                                    let signature = fingerprint.finalize()
                                    let old = self.previousAreas[key]
                                    let changed = old.map { $0.signature != signature } ?? false
                                    let changedAt = changed ? now : old?.changedAt ?? -.infinity
                                    let settling = now - changedAt < 0.25
                                    self.previousAreas[key] = AreaState(signature: signature, changedAt: changedAt, seenAt: now,
                                                                      hadSecret: !hits.isEmpty || (settling && old?.hadSecret == true))
                                    if settling && (!hits.isEmpty || old?.hadSecret == true) {
                                        unstable = true
                                        elementMasks += window.visibleParts(of: frame, in: windows).map {
                                            Mask(rect: $0, rule: "scrolling-text", app: window.app, windowID: window.id, anchor: window.bounds)
                                        }
                                    }
                                }
                                for hit in hits {
                                    guard let range = Self.stringRange(hit.start..<hit.end, in: slice.text) else { continue }
                                    let local = NSRange(range, in: slice.text)
                                    var axRange = CFRange(location: local.location + slice.offset, length: local.length)
                                    var result: CFTypeRef?
                                    var bounds = frame
                                    if hit.rule == "private-key" {
                                        bounds = window.bounds
                                    } else if let value = AXValueCreate(.cfRange, &axRange),
                                              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &result) == .success,
                                              let result, CFGetTypeID(result) == AXValueGetTypeID() {
                                        var exact = CGRect.zero
                                        if AXValueGetValue(result as! AXValue, .cgRect, &exact), !exact.isEmpty, !exact.isNull {
                                            bounds = exact
                                        }
                                    }
                                    let limit = hit.rule == "private-key" ? window.bounds : frame.intersection(window.bounds)
                                    bounds = bounds.insetBy(dx: -4, dy: -4).intersection(limit)
                                    if !bounds.isEmpty && !bounds.isNull {
                                        elementMasks += window.visibleParts(of: bounds, in: windows).map {
                                            Mask(rect: $0, rule: hit.rule, app: window.app, hash: hit.hash, windowID: window.id, anchor: window.bounds)
                                        }
                                    }
                                }
                                self.storeMasks(elementMasks, for: key)
                            } else {
                                if self.previousAreas[key]?.hadSecret == true || self.cachedMasks[key]?.isEmpty == false {
                                    if let old = self.previousAreas[key] {
                                        self.previousAreas[key] = AreaState(signature: old.signature, changedAt: old.changedAt,
                                                                           seenAt: ProcessInfo.processInfo.systemUptime, hadSecret: true)
                                    }
                                    self.storeMasks(window.visibleParts(of: frame, in: windows).map {
                                        Mask(rect: $0, rule: "unreadable-text", app: window.app, windowID: window.id, anchor: window.bounds)
                                    }, for: key)
                                }
                            }
                        }
                        if let children = axValue(element, kAXVisibleChildrenAttribute) as? [AXUIElement] ?? axValue(element, kAXChildrenAttribute) as? [AXUIElement] {
                            pending.append(contentsOf: children.prefix(max(0, remaining - pending.count)))
                        }
                    }
                    if pending.isEmpty, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline,
                       self.currentGeneration() == revision {
                        self.cachedMasks = self.cachedMasks.filter { $0.key.window != window.id || seenAreas.contains($0.key) }
                        self.cachedMaskCount = self.cachedMasks.values.reduce(0) { $0 + $1.count }
                        self.previousAreas = self.previousAreas.filter { $0.key.window != window.id || seenAreas.contains($0.key) }
                    }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            let ids = Set(windows.map(\.id))
            self.previousAreas = self.previousAreas.filter { ids.contains($0.key.window) && now - $0.value.seenAt < 2 }
            if self.previousAreas.count > 900 { self.previousAreas.removeAll() }
            self.cachedMasks = self.cachedMasks.filter { ids.contains($0.key.window) }
            self.cachedMaskCount = self.cachedMasks.values.reduce(0) { $0 + $1.count }
            self.overflowWindows.formIntersection(ids)
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
                self.onMasks?(masks)
                self.onPaths?(paths)
                if unstable { self.scheduleStabilityCheck(generation: revision) }
            }
        }
    }

    private func storeMasks(_ masks: [Mask], for key: AreaID) {
        guard !overflowWindows.contains(key.window) else { return }
        let previousCount = cachedMasks[key]?.count ?? 0
        if cachedMaskCount - previousCount + masks.count > 4096 {
            overflowWindows.insert(key.window)
            cachedMasks = cachedMasks.filter { $0.key.window != key.window }
            cachedMaskCount = cachedMasks.values.reduce(0) { $0 + $1.count }
        } else {
            if masks.isEmpty { cachedMasks.removeValue(forKey: key) }
            else { cachedMasks[key] = masks }
            cachedMaskCount += masks.count - previousCount
        }
    }

    private func visibleMasks(windows: [ScreenWindow]) -> [Mask] {
        var result: [Mask] = []
        for masks in cachedMasks.values {
            for original in masks {
                guard let window = windows.first(where: { $0.id == original.windowID }) else { continue }
                var mask = original
                if let anchor = mask.anchor {
                    if anchor.size != window.bounds.size {
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
        for window in windows where overflowWindows.contains(window.id) {
            result += window.visibleParts(of: window.bounds, in: windows).map {
                Mask(rect: $0, rule: "scan-capacity", app: window.app, windowID: window.id, anchor: window.bounds)
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
                guard AXObserverCreate(target.pid, { _, _, _, context in
                    guard let context else { return }
                    let callback = Unmanaged<AXCallbackContext>.fromOpaque(context).takeUnretainedValue()
                    callback.owner?.enqueueInvalidation(generation: callback.generation)
                }, &observer) == .success, let observer else { continue }
                let watch = AXWatch(observer: observer, context: AXCallbackContext(self, generation: generation))
                watches[target.pid] = watch
                installed[target.pid] = watch
            }
            guard let watch = watches[target.pid], watch.registered.count < 256 else { continue }
            AXUIElementSetMessagingTimeout(target.element, 0.015)
            for name in target.names {
                guard currentGeneration() == generation, ProcessInfo.processInfo.systemUptime < deadline, attempts < 24 else { break }
                let key = "\(CFHash(target.element)):\(name)"
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

    fileprivate func enqueueInvalidation(generation: Int) {
        precondition(Thread.isMainThread)
        guard currentGeneration() == generation, invalidation == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.invalidation = nil
            guard self.currentGeneration() == generation else { return }
            self.onInvalidation?()
        }
        invalidation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    private func scheduleStabilityCheck(generation: Int) {
        guard stabilityCheck == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stabilityCheck = nil
            guard self.currentGeneration() == generation else { return }
            self.onInvalidation?()
        }
        stabilityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
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
        stabilityCheck?.cancel()
        let watches = Array(observers.values)
        let remove = {
            for watch in watches { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes) }
        }
        if Thread.isMainThread { remove() } else { DispatchQueue.main.async(execute: remove) }
    }
}
