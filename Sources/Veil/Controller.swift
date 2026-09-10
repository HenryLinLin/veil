import AppKit

final class VeilController {
    private(set) var armed = false
    private(set) var masks: [Mask] = []
    private(set) var error: String?
    private var engine: CoreEngine?
    private let accessibility = AccessibilityReader()
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
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        changed?()
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        armed = false
        accessibility.stop()
        engine = nil
        textMasks.removeAll()
        masks.removeAll()
        tracker.reset()
        overlays.clear()
        changed?()
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
        masks = tracker.update(current + textMasks, windows: windows)
        overlays.show(masks)
        changed?()
    }
}
