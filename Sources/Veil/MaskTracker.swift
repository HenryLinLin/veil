import Foundation
import CoreGraphics

final class MaskTracker {
    private struct Held {
        var mask: Mask
        var expiry: TimeInterval
        var windowBounds: CGRect?
    }
    private var held: [Held] = []
    func update(_ fresh: [Mask], windows: [ScreenWindow], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Mask] {
        let fresh = fresh.compactMap { original -> Mask? in
            guard original.windowID != 0 else { return original }
            guard let window = windows.first(where: { $0.id == original.windowID }) else { return nil }
            var mask = original
            if let anchor = original.anchor {
                mask.rect = anchor.size == window.bounds.size
                    ? mask.rect.offsetBy(dx: window.bounds.minX - anchor.minX, dy: window.bounds.minY - anchor.minY)
                    : window.bounds
            }
            mask.anchor = window.bounds
            return mask
        }
        held = held.compactMap { entry in
            guard entry.expiry > now else { return nil }
            var next = entry
            if entry.mask.windowID != 0 {
                guard let window = windows.first(where: { $0.id == entry.mask.windowID }) else { return nil }
                if let old = entry.windowBounds {
                    next.mask.rect = old.size == window.bounds.size
                        ? next.mask.rect.offsetBy(dx: window.bounds.minX - old.minX, dy: window.bounds.minY - old.minY)
                        : window.bounds
                }
                next.windowBounds = window.bounds
            }
            return next
        }
        held.removeAll { entry in
            fresh.contains {
                $0.rule == entry.mask.rule && $0.windowID == entry.mask.windowID &&
                    $0.hash == entry.mask.hash && $0.rect.contains(entry.mask.rect)
            }
        }
        for mask in fresh {
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
    func invalidate(windowIDs: Set<CGWindowID>) {
        held.removeAll { windowIDs.contains($0.mask.windowID) }
    }
    func reset() { held.removeAll() }
}
