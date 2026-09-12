import AppKit

final class VeilController {
    private(set) var armed = false
    private(set) var masks: [Mask] = []
    private(set) var error: String?
    private var engine: CoreEngine?
    private let accessibility = AccessibilityReader()
    private let capture = ScreenCapture()
    private var ocrMasks: [CGDirectDisplayID: [Mask]] = [:]
    private var textMasks: [Mask] = []
    var changed: (() -> Void)?
    let overlays = OverlayManager()
    private var timer: Timer?
    private let tracker = MaskTracker()
    func toggle() { armed ? stop() : start() }
    func start() {
        guard !armed else { return }
        do { engine = try CoreEngine() } catch { self.error = error.localizedDescription; changed?(); return }
        self.error = nil
        accessibility.onMasks = { [weak self] masks in self?.textMasks = masks }
        armed = true
        capture.onScannedFrame = { [weak self] frame, lines in self?.scanned(frame, lines: lines) }
        capture.onFailure = { [weak self] message in self?.error = message; self?.changed?() }
        Task { @MainActor in
            guard self.armed else { return }
            do { try await self.capture.start() }
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
        } catch {
            self.error = error.localizedDescription
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
        overlays.show(masks)
        changed?()
    }
}
