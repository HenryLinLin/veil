import AppKit

final class VeilController {
    private(set) var armed = false
    private(set) var masks: [Mask] = []
    var changed: (() -> Void)?
    let overlays = OverlayManager()
    private var timer: Timer?
    func toggle() { armed ? stop() : start() }
    func start() {
        guard !armed else { return }
        armed = true
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        changed?()
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        armed = false
        masks.removeAll()
        overlays.clear()
        changed?()
    }
    private func tick() {
        let windows = ScreenWindow.visible()
        masks = windows.flatMap { window -> [Mask] in
            guard let rule = WindowRule.defaults.first(where: { $0.matches(window) }) else { return [] }
            return window.visibleParts(of: window.bounds, in: windows).map {
                Mask(rect: $0, rule: rule.id, app: window.app, windowID: window.id)
            }
        }
        overlays.show(masks)
        changed?()
    }
}
