import AppKit

final class VeilController {
    private(set) var armed = false
    private(set) var masks: [Mask] = []
    private(set) var error: String?
    private var engine: CoreEngine?
    private let accessibility = AccessibilityReader()
    private let capture = ScreenCapture()
    private let feed = FeedManager()
    var feedMode = false
    private var ocrMasks: [CGDirectDisplayID: [Mask]] = [:]
    private var textMasks: [Mask] = []
    var changed: (() -> Void)?
    let overlays = OverlayManager()
    private var timer: Timer?
    private let tracker = MaskTracker()
    func toggleMode() {
        let resume = armed
        if resume { stop() }
        feedMode.toggle()
        if resume { start() }
        changed?()
    }
    func toggle() { armed ? stop() : start() }
    func start() {
        guard !armed else { return }
        do { engine = try CoreEngine() } catch { self.error = error.localizedDescription; changed?(); return }
        self.error = nil
        accessibility.onMasks = { [weak self] masks in self?.textMasks = masks }
        armed = true
        capture.onScannedFrame = { [weak self] frame, lines in self?.scanned(frame, lines: lines) }
        capture.onFailure = { [weak self] message in self?.error = message; self?.feed.clear(); self?.changed?() }
        Task { @MainActor in
            guard self.armed else { return }
            do { try await self.capture.start(fullFrameScanning: self.feedMode) }
            catch { self.error = "Screen Recording is required for OCR: " + error.localizedDescription; self.changed?() }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        changed?()
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        armed = false
        accessibility.stop()
        capture.stop()
        feed.closeAll()
        ocrMasks.removeAll()
        engine = nil
        textMasks.removeAll()
        masks.removeAll()
        tracker.reset()
        overlays.clear()
        changed?()
    }
    private func scanned(_ frame: CapturedFrame, lines: [OCRLine]) {
        guard armed, let engine else { return }
        let windows = ScreenWindow.visible()
        var fresh: [Mask] = []
        do {
            for line in lines {
                let owner = windows.first { $0.bounds.contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY)) && $0.layer == 0 }
                for hit in try engine.scan(line.text, title: owner?.title ?? "", ocr: true) {
                    let rect = hit.rule == "private-key" ? (owner?.bounds ?? frame.displayBounds) :
                        (line.bounds(forUTF8Range: hit.start..<hit.end) ?? line.bounds).insetBy(dx: -4, dy: -4)
                    fresh.append(Mask(rect: rect.intersection(frame.displayBounds), rule: hit.rule,
                                      app: owner?.app ?? "screen", hash: hit.hash, windowID: owner?.id ?? 0))
                }
            }
            ocrMasks[frame.displayID] = (ocrMasks[frame.displayID] ?? []).filter { !$0.rect.intersects(frame.scannedBounds) } + fresh
            if feedMode {
                let windowMasks = windows.filter { window in WindowRule.defaults.contains { $0.matches(window) } }
                    .map { Mask(rect: $0.bounds, rule: "sensitive-window", app: $0.app, windowID: $0.id) }
                let current = fresh + windowMasks + textMasks
                let sx = Double(frame.image.width) / frame.displayBounds.width
                let sy = Double(frame.image.height) / frame.displayBounds.height
                let rects = current.compactMap { mask -> CGRect? in
                    let r = mask.rect.intersection(frame.displayBounds)
                    guard !r.isNull, !r.isEmpty else { return nil }
                    return CGRect(x: (r.minX - frame.displayBounds.minX) * sx, y: (r.minY - frame.displayBounds.minY) * sy, width: r.width * sx, height: r.height * sy)
                }
                feed.publish(displayID: frame.displayID, image: frame.image, masks: rects, delay: 0.5)
            }
        } catch {
            self.error = error.localizedDescription
            feed.clear()
            ocrMasks[frame.displayID] = [Mask(rect: frame.displayBounds, rule: "detector-error", app: "screen")]
        }
    }
    private func tick() {
        let windows = ScreenWindow.visible()
        let current = windows.flatMap { window -> [Mask] in
            guard let rule = WindowRule.defaults.first(where: { $0.matches(window) }) else { return [] }
            return window.visibleParts(of: window.bounds, in: windows).map {
                Mask(rect: $0, rule: rule.id, app: window.app, windowID: window.id)
            }
        }
        if let engine { accessibility.scan(windows: windows, engine: engine) }
        masks = tracker.update(current + textMasks + ocrMasks.values.flatMap { $0 }, windows: windows)
        if feedMode { overlays.clear() } else { overlays.show(masks) }
        changed?()
    }
}
