import Foundation

final class MaskTracker {
    private struct Held {
        var mask: Mask
        var expiry: TimeInterval
        var windowBounds: CGRect?
    }
    private var held: [Held] = []
    func update(_ fresh: [Mask], windows: [ScreenWindow], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Mask] {
        held = held.compactMap { entry in
            guard entry.expiry > now else { return nil }
            var next = entry
            if entry.mask.windowID != 0 {
                guard let window = windows.first(where: { $0.id == entry.mask.windowID }) else { return nil }
                if let old = entry.windowBounds {
                    next.mask.rect = next.mask.rect.offsetBy(dx: window.bounds.minX - old.minX, dy: window.bounds.minY - old.minY)
                }
                next.windowBounds = window.bounds
            }
            return next
        }
        for mask in fresh {
            held.removeAll { $0.mask.rule == mask.rule && $0.mask.windowID == mask.windowID && $0.mask.rect.intersects(mask.rect) }
            held.append(Held(mask: mask, expiry: now + 0.5, windowBounds: windows.first { $0.id == mask.windowID }?.bounds))
        }
        return held.flatMap { entry -> [Mask] in
            guard let window = windows.first(where: { $0.id == entry.mask.windowID }) else { return [entry.mask] }
            return window.visibleParts(of: entry.mask.rect, in: windows).map { rect in
                var mask = entry.mask
                mask.rect = rect
                return mask
            }
        }
    }
    func reset() { held.removeAll() }
}
