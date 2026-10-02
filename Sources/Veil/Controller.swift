import AppKit
import Carbon

final class VeilController {
    private(set) var armed = false
    private(set) var masks: [Mask] = []
    private(set) var error: String?
    private var engine: CoreEngine?
    private let accessibility = AccessibilityReader()
    private var capture = ScreenCapture()
    private let feed = FeedManager()
    let store = PreferencesStore()
    var feedMode: Bool { store.current.mode == "feed" }
    private let watcher = AutoArm()
    private let peekWarning = PeekWarning()
    private var peekTimer: Timer?
    private(set) var peeking = false
    private var manualSession = false
    private var sessionGeneration = 0
    private var captureTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var rescanWork: DispatchWorkItem?
    private var scrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var scrollProtection = ScrollProtection()
    private var scanFailures = ScanFailures()
    private var visibleWindows: [ScreenWindow] = []
    private var displayBounds: [CGRect] = []
    private(set) var notice: String?
    init() {
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self, self.armed else { return }
            let manual = self.manualSession
            self.stop(showSummary: false)
            self.start(manual: manual)
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            self?.stop(showSummary: false)
        }
    }
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
            peekTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(self.store.current.peekKey)) { self.setPeek(false) }
            }
            if let peekTimer { RunLoop.main.add(peekTimer, forMode: .common) }
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
    private var scene: [WindowSignature] = []
    private var sceneStableSince: TimeInterval = .infinity
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
        let ocrEngine: CoreEngine
        do {
            let config = store.current.engineJSON()
            engine = try CoreEngine(config: config)
            ocrEngine = try CoreEngine(config: config)
        } catch {
            engine = nil
            self.error = error.localizedDescription
            changed?()
            return
        }
        if feedMode && !feed.isAvailable {
            engine = nil
            self.error = "Clean Feed requires Metal. Select Overlay on this Mac."
            changed?()
            return
        }
        self.error = nil
        manualSession = manual
        session.start()
        accessibility.onMasks = { [weak self] masks, startedAt in
            guard let self, self.armed else { return }
            self.textMasks = masks.filter { self.scrollProtection.accepts(windowID: $0.windowID, timestamp: startedAt) }
        }
        accessibility.onScanCompleted = { [weak self] ids, startedAt in
            guard let self, self.armed, !self.store.current.ocr, !self.feedMode else { return }
            self.scrollProtection.accessibilityScanned(windowIDs: ids, startedAt: startedAt)
            self.refreshMasks()
        }
        accessibility.onInvalidation = { [weak self] in self?.axDirty = true }
        accessibility.onContentInvalidation = { [weak self] ids in
            self?.protectScrollingWindows(ids, at: ProcessInfo.processInfo.systemUptime)
        }
        accessibility.onPaths = { [weak self] found in
            guard let self, self.armed else { return }
            for (id, path) in found {
                if let title = self.scanTitles[id] { self.paths[id] = (title, path) }
            }
        }
        axDirty = true
        lastAX = -.infinity
        scene = []
        sceneStableSince = .infinity
        armed = true
        sessionGeneration += 1
        let revision = sessionGeneration
        let capture = ScreenCapture(engine: ocrEngine)
        self.capture = capture
        displayBounds = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayBounds($0.uint32Value) }
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in self?.scrolled(event) }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.scrolled(event)
            return event
        }
        if feedMode {
            feed.prepare(displayIDs: NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
        }
        capture.onScannedFrame = { [weak self] frame, masks in
            guard let self, self.armed, self.sessionGeneration == revision else { return }
            self.scanned(frame, fresh: masks)
        }
        capture.onFailure = { [weak self] message, displayID in
            guard let self, self.armed, self.sessionGeneration == revision else { return }
            self.error = message
            let ids = displayID.map { [$0] } ?? NSScreen.screens.compactMap {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }
            for id in ids { self.scanFailures.failed(displayID: id, at: ProcessInfo.processInfo.systemUptime) }
            self.capture.requestFullScan()
            self.feed.clear(displayID: displayID)
            self.refreshMasks()
            self.changed?()
        }
        captureTask = Task { @MainActor [weak self] in
            guard let self else { capture.stop(); return }
            defer {
                if !self.armed || self.sessionGeneration != revision || Task.isCancelled { capture.stop() }
                if self.sessionGeneration == revision { self.captureTask = nil }
            }
            guard self.armed, self.sessionGeneration == revision, !Task.isCancelled,
                  self.store.current.ocr || self.feedMode else { return }
            guard CGPreflightScreenCaptureAccess() else {
                self.error = "Grant Screen Recording in Permissions & Test to enable OCR and Clean Feed."
                self.changed?()
                return
            }
            do { try await capture.start(ocrEnabled: self.store.current.ocr || self.feedMode, fullFrameScanning: self.feedMode) }
            catch {
                guard self.armed, self.sessionGeneration == revision, !Task.isCancelled else { return }
                self.error = "Screen Recording is required for OCR: " + error.localizedDescription
                self.changed?()
            }
        }
        tick()
        let clock = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
        changed?()
    }
    func stop(showSummary: Bool = true) {
        let hadSession = armed
        sessionGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        rescanWork?.cancel()
        rescanWork = nil
        timer?.invalidate()
        timer = nil
        armed = false
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        scrollMonitor = nil
        localScrollMonitor = nil
        scrollProtection.reset()
        scanFailures.reset()
        visibleWindows.removeAll()
        displayBounds.removeAll()
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
    private func scrolled(_ event: NSEvent) {
        guard armed, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        if let localWindow = event.window, localWindow.title != "Veil Test" { return }
        let location = event.cgEvent?.location ?? CGPoint(x: NSEvent.mouseLocation.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - NSEvent.mouseLocation.y)
        guard let window = visibleWindows.first(where: { $0.layer == 0 && $0.bounds.contains(location) }),
              !store.current.allowedPaths.contains(path(for: window)) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let timestamp = event.timestamp.isFinite && event.timestamp <= now && now - event.timestamp < 2 ? event.timestamp : now
        protectScrollingWindows([window.id], at: timestamp)
    }

    private func protectScrollingWindows(_ ids: Set<CGWindowID>, at timestamp: TimeInterval) {
        guard armed else { return }
        let affected = visibleWindows.filter { ids.contains($0.id) && !store.current.allowedPaths.contains(path(for: $0)) }
        guard !affected.isEmpty else { return }
        let ids = Set(affected.map(\.id))
        for window in affected {
            scrollProtection.scrolled(windowID: window.id, at: timestamp)
            accessibility.prioritize(pid: window.pid)
        }
        tracker.invalidate(windowIDs: ids)
        accessibility.invalidateContent(windowIDs: ids)
        textMasks.removeAll { ids.contains($0.windowID) }
        for id in Array(ocrMasks.keys) { ocrMasks[id]?.removeAll { ids.contains($0.windowID) } }
        capture.requestFullScan()
        scheduleRescan()
        refreshMasks()
    }

    private func scanned(_ frame: CapturedFrame, fresh: [Mask]) {
        guard armed else { return }
        let windows = ScreenWindow.visible()
        visibleWindows = windows
        updateScene(windows)
        guard frame.windows == scene, sceneStableSince <= frame.timestamp else {
            capture.requestFullScan()
            if feedMode { feed.clear(displayID: frame.displayID) }
            return
        }
        let fresh = fresh.filter { scrollProtection.accepts(windowID: $0.windowID, timestamp: frame.timestamp) }
        ocrMasks[frame.displayID] = (ocrMasks[frame.displayID] ?? []).filter { !$0.rect.intersects(frame.scannedBounds) } + fresh
        scrollProtection.scanned(bounds: frame.scannedBounds, timestamp: frame.timestamp)
        if scanFailures.scanned(displayID: frame.displayID, displayBounds: frame.displayBounds,
                                scannedBounds: frame.scannedBounds, timestamp: frame.timestamp), scanFailures.since.isEmpty {
            error = nil
        }
        refreshMasks()
        if feedMode {
            let windowMasks = windows.filter { windowRule(for: $0) != nil }
                .map { Mask(rect: $0.bounds, rule: "sensitive-window", app: $0.app, windowID: $0.id) }
            let staleWindows = windows.filter { !scrollProtection.accepts(windowID: $0.id, timestamp: frame.timestamp) }
                .map { Mask(rect: $0.bounds, rule: "scrolling-text", app: $0.app, windowID: $0.id) }
            let current = (fresh + windowMasks + textMasks + scrollMasks() + staleWindows + failureMasks()).filter { permitted($0, in: windows) }
            let sx = Double(frame.image.width) / frame.displayBounds.width
            let sy = Double(frame.image.height) / frame.displayBounds.height
            let rects = current.compactMap { mask -> CGRect? in
                let r = mask.rect.intersection(frame.displayBounds)
                guard !r.isNull, !r.isEmpty else { return nil }
                return CGRect(x: (r.minX - frame.displayBounds.minX) * sx, y: (r.minY - frame.displayBounds.minY) * sy, width: r.width * sx, height: r.height * sy)
            }
            feed.publish(displayID: frame.displayID, image: frame.image, masks: rects, delay: store.current.delay)
        }
    }

    private func scheduleRescan() {
        rescanWork?.cancel()
        let revision = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.armed, self.sessionGeneration == revision else { return }
            self.rescanWork = nil
            self.axDirty = true
            if self.store.current.ocr || self.feedMode { self.capture.rescanNow() }
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollProtection.settleInterval + 0.02, execute: work)
    }

    private func scrollMasks() -> [Mask] {
        visibleWindows.filter { scrollProtection.windowIDs.contains($0.id) }.flatMap { window in
            window.visibleParts(of: window.bounds, in: visibleWindows).map {
                Mask(rect: $0, rule: "scrolling-text", app: window.app, windowID: window.id)
            }
        }
    }

    private func failureMasks() -> [Mask] {
        scanFailures.since.keys.map { Mask(rect: CGDisplayBounds($0), rule: "detector-error", app: "screen") }
    }

    private func refreshMasks() {
        guard armed else { return }
        let released = scrollProtection.update(windows: visibleWindows, displays: displayBounds,
                                               now: ProcessInfo.processInfo.systemUptime)
        tracker.invalidate(windowIDs: released)
        if store.current.ocr || feedMode { textMasks.removeAll { released.contains($0.windowID) } }
        let current = visibleWindows.flatMap { window -> [Mask] in
            guard let rule = windowRule(for: window) else { return [] }
            return window.visibleParts(of: window.bounds, in: visibleWindows).map {
                Mask(rect: $0, rule: rule.id, app: window.app, windowID: window.id)
            }
        }
        let detected = (current + textMasks + ocrMasks.values.flatMap { $0 }).filter { permitted($0, in: visibleWindows) }
        masks = tracker.update(detected, windows: visibleWindows)
        session.record(masks)
        masks += scrollMasks() + failureMasks()
        if feedMode || peeking { overlays.clear() } else { overlays.show(masks) }
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
    private func updateScene(_ windows: [ScreenWindow]) {
        let next = windows.map { WindowSignature(id: $0.id, pid: $0.pid, bounds: $0.bounds, layer: $0.layer, title: $0.title.hashValue) }
        if next != scene || !sceneStableSince.isFinite {
            scene = next
            sceneStableSince = ProcessInfo.processInfo.systemUptime
            scheduleRescan()
        }
    }
    private func tick() {
        let windows = ScreenWindow.visible()
        updateScene(windows)
        visibleWindows = windows
        paths = paths.filter { id, value in windows.contains { $0.id == id && $0.title.hashValue == value.title } }
        capture.updatePaths(paths)
        let now = ProcessInfo.processInfo.systemUptime
        if let engine, !accessibility.isScanning, (axDirty && now - lastAX >= 0.1) || now - lastAX >= 0.4 {
            scanTitles = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.title.hashValue) })
            axDirty = false
            lastAX = now
            accessibility.scan(windows: windows, engine: engine)
        }
        refreshMasks()
        changed?()
    }

    deinit {
        captureTask?.cancel()
        rescanWork?.cancel()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }
}
