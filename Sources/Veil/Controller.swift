import AppKit
import Carbon

final class VeilController {
    private(set) var armed = false
    private(set) var masks: [Mask] = []
    private(set) var error: String?
    private var engine: CoreEngine?
    private let accessibility = AccessibilityReader()
    private let capture = ScreenCapture()
    private let feed = FeedManager()
    let store = PreferencesStore()
    var feedMode: Bool { store.current.mode == "feed" }
    private let watcher = AutoArm()
    private let peekWarning = PeekWarning()
    private var peekTimer: Timer?
    private(set) var peeking = false
    private var manualSession = false
    private(set) var notice: String?
    func configure() {
        watcher.onSharing = { [weak self] active, singleWindow in
            guard let self else { return }
            if active {
                if singleWindow { self.notice = "Single-window share detected: use Clean Feed." }
                self.start(manual: false)
            } else if !self.manualSession { self.stop() }
        }
        watcher.configure(enabled: store.current.autoArm)
    }
    func reload() {
        let resume = armed
        let manual = manualSession
        if resume { stop(showSummary: false) }
        configure()
        if resume { start(manual: manual) }
        changed?()
    }
    func setPeek(_ down: Bool) {
        let show = down && armed && !feedMode
        guard show != peeking else { return }
        peeking = show
        peekTimer?.invalidate()
        peekTimer = nil
        if show {
            overlays.clear()
            peekWarning.show()
            peekTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(self.store.current.peekKey)) { self.setPeek(false) }
            }
        } else {
            peekWarning.hide()
            if armed { tick() }
        }
        changed?()
    }
    private var ocrMasks: [CGDirectDisplayID: [Mask]] = [:]
    private var textMasks: [Mask] = []
    private var paths: [CGWindowID: (title: Int, path: String)] = [:]
    private var scanTitles: [CGWindowID: Int] = [:]
    private var axDirty = true
    private var lastAX: TimeInterval = -.infinity
    var changed: (() -> Void)?
    let overlays = OverlayManager()
    private var timer: Timer?
    private let tracker = MaskTracker()
    private let session = SessionSummary()
    func toggleMode() {
        let resume = armed
        if resume { stop(showSummary: false) }
        store.current.mode = feedMode ? "overlay" : "feed"
        store.save()
        if resume { start() }
        changed?()
    }
    func shutdown() { stop(showSummary: false); watcher.stop() }
    func toggle() { armed ? stop() : start() }
    func start(manual: Bool = true) {
        guard !armed else { if manual { manualSession = true }; return }
        do { engine = try CoreEngine(config: store.current.engineJSON()) } catch { self.error = error.localizedDescription; changed?(); return }
        self.error = nil
        manualSession = manual
        session.start()
        accessibility.onMasks = { [weak self] masks in self?.textMasks = masks }
        accessibility.onInvalidation = { [weak self] in self?.axDirty = true }
        accessibility.onPaths = { [weak self] found in
            guard let self, self.armed else { return }
            for (id, path) in found {
                if let title = self.scanTitles[id] { self.paths[id] = (title, path) }
            }
        }
        axDirty = true
        lastAX = -.infinity
        armed = true
        capture.onScannedFrame = { [weak self] frame, lines in self?.scanned(frame, lines: lines) }
        capture.onFailure = { [weak self] message in self?.error = message; self?.feed.clear(); self?.changed?() }
        Task { @MainActor in
            guard self.armed else { return }
            do { try await self.capture.start(ocrEnabled: self.store.current.ocr, fullFrameScanning: self.feedMode) }
            catch { self.error = "Screen Recording is required for OCR: " + error.localizedDescription; self.changed?() }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        changed?()
    }
    func stop(showSummary: Bool = true) {
        let hadSession = armed
        timer?.invalidate()
        timer = nil
        armed = false
        manualSession = false
        setPeek(false)
        accessibility.stop()
        capture.stop()
        feed.closeAll()
        ocrMasks.removeAll()
        engine = nil
        textMasks.removeAll()
        paths.removeAll()
        scanTitles.removeAll()
        masks.removeAll()
        tracker.reset()
        overlays.clear()
        changed?()
        if hadSession && showSummary { session.show() }
    }
    private func scanned(_ frame: CapturedFrame, lines: [OCRLine]) {
        guard armed, let engine else { return }
        let windows = ScreenWindow.visible()
        var fresh: [Mask] = []
        do {
            for line in lines {
                let owner = windows.first { $0.bounds.contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY)) && $0.layer == 0 }
                for hit in try engine.scan(line.text, title: owner?.title ?? "", path: owner.map { path(for: $0) } ?? "", ocr: true) {
                    let rect = hit.rule == "private-key" ? (owner?.bounds ?? frame.displayBounds) :
                        (line.bounds(forUTF8Range: hit.start..<hit.end) ?? line.bounds).insetBy(dx: -4, dy: -4)
                    fresh.append(Mask(rect: rect.intersection(frame.displayBounds), rule: hit.rule,
                                      app: owner?.app ?? "screen", hash: hit.hash, windowID: owner?.id ?? 0, anchor: owner?.bounds))
                }
            }
            ocrMasks[frame.displayID] = (ocrMasks[frame.displayID] ?? []).filter { !$0.rect.intersects(frame.scannedBounds) } + fresh
            if feedMode {
                let windowMasks = windows.filter { window in self.windowRule(for: window) != nil }
                    .map { Mask(rect: $0.bounds, rule: "sensitive-window", app: $0.app, windowID: $0.id) }
                let current = (fresh + windowMasks + textMasks).filter { permitted($0, in: windows) }
                let sx = Double(frame.image.width) / frame.displayBounds.width
                let sy = Double(frame.image.height) / frame.displayBounds.height
                let rects = current.compactMap { mask -> CGRect? in
                    let r = mask.rect.intersection(frame.displayBounds)
                    guard !r.isNull, !r.isEmpty else { return nil }
                    return CGRect(x: (r.minX - frame.displayBounds.minX) * sx, y: (r.minY - frame.displayBounds.minY) * sy, width: r.width * sx, height: r.height * sy)
                }
                feed.publish(displayID: frame.displayID, image: frame.image, masks: rects, delay: store.current.delay)
            }
        } catch {
            self.error = error.localizedDescription
            feed.clear()
            ocrMasks[frame.displayID] = [Mask(rect: frame.displayBounds, rule: "detector-error", app: "screen")]
        }
    }
    private func path(for window: ScreenWindow) -> String {
        guard let value = paths[window.id], value.title == window.title.hashValue else { return "" }
        return value.path
    }
    private func windowRule(for window: ScreenWindow) -> WindowRule? {
        if store.current.allowedPaths.contains(path(for: window)) { return nil }
        return store.current.windowRules.first { $0.matches(window) && !store.current.disabledRules.contains($0.id) }
    }
    private func permitted(_ mask: Mask, in windows: [ScreenWindow]) -> Bool {
        guard !store.current.disabledRules.contains(mask.rule) else { return false }
        if let window = windows.first(where: { $0.id == mask.windowID }) {
            return !store.current.allowedPaths.contains(path(for: window))
        }
        return true
    }
    private func tick() {
        let windows = ScreenWindow.visible()
        let current = windows.flatMap { window -> [Mask] in
            guard let rule = windowRule(for: window) else { return [] }
            return window.visibleParts(of: window.bounds, in: windows).map {
                Mask(rect: $0, rule: rule.id, app: window.app, windowID: window.id)
            }
        }
        paths = paths.filter { id, value in windows.contains { $0.id == id && $0.title.hashValue == value.title } }
        let now = ProcessInfo.processInfo.systemUptime
        if let engine, !accessibility.isScanning, (axDirty && now - lastAX >= 0.2) || now - lastAX >= 0.8 {
            scanTitles = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.title.hashValue) })
            axDirty = false
            lastAX = now
            accessibility.scan(windows: windows, engine: engine)
        }
        let detected = (current + textMasks + ocrMasks.values.flatMap { $0 }).filter { permitted($0, in: windows) }
        masks = tracker.update(detected, windows: windows)
        session.record(masks)
        if feedMode || peeking { overlays.clear() } else { overlays.show(masks) }
        changed?()
    }
}
