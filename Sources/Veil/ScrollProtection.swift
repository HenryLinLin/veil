import Foundation
import CoreGraphics

struct ScrollProtection {
    private struct Pending {
        let changedAt: TimeInterval
        var coverage: [CGRect] = []
        var accessibilityComplete = false
    }
    private var pending: [CGWindowID: Pending] = [:]
    private var lastMotion: [CGWindowID: TimeInterval] = [:]
    let settleInterval: TimeInterval = 0.12
    var windowIDs: Set<CGWindowID> { Set(pending.keys) }

    mutating func scrolled(windowID: CGWindowID, at timestamp: TimeInterval) {
        guard timestamp.isFinite, timestamp >= (lastMotion[windowID] ?? -.infinity) else { return }
        lastMotion[windowID] = timestamp
        pending[windowID] = Pending(changedAt: timestamp)
    }

    func accepts(windowID: CGWindowID, timestamp: TimeInterval) -> Bool {
        timestamp >= (lastMotion[windowID].map { $0 + settleInterval } ?? -.infinity)
    }

    mutating func scanned(bounds: CGRect, timestamp: TimeInterval) {
        guard !bounds.isNull, !bounds.isEmpty else { return }
        for id in Array(pending.keys) {
            guard var state = pending[id], timestamp >= state.changedAt + settleInterval else { continue }
            state.coverage.removeAll { bounds.contains($0) }
            if !state.coverage.contains(where: { $0.contains(bounds) }) { state.coverage.append(bounds) }
            pending[id] = state
        }
    }

    mutating func accessibilityScanned(windowIDs: Set<CGWindowID>, startedAt: TimeInterval) {
        for id in windowIDs {
            guard var state = pending[id], startedAt >= state.changedAt + settleInterval else { continue }
            state.accessibilityComplete = true
            pending[id] = state
        }
    }

    @discardableResult
    mutating func update(windows: [ScreenWindow], displays: [CGRect], now: TimeInterval) -> Set<CGWindowID> {
        let visibleIDs = Set(windows.map(\.id))
        lastMotion = lastMotion.filter { visibleIDs.contains($0.key) }
        var released: Set<CGWindowID> = []
        for (id, state) in pending {
            guard let window = windows.first(where: { $0.id == id }) else {
                released.insert(id)
                continue
            }
            guard now >= state.changedAt + settleInterval else { continue }
            var uncovered = displays.flatMap { display in window.visibleParts(of: window.bounds.intersection(display), in: windows) }
            for rect in state.coverage { uncovered = uncovered.flatMap { subtract($0, rect) } }
            if state.accessibilityComplete || uncovered.isEmpty { released.insert(id) }
        }
        for id in released { pending.removeValue(forKey: id) }
        return released
    }

    mutating func reset() {
        pending.removeAll()
        lastMotion.removeAll()
    }
}

struct ScanFailures {
    private(set) var since: [CGDirectDisplayID: TimeInterval] = [:]

    mutating func failed(displayID: CGDirectDisplayID, at timestamp: TimeInterval) {
        since[displayID] = max(since[displayID] ?? -.infinity, timestamp)
    }

    @discardableResult
    mutating func scanned(displayID: CGDirectDisplayID, displayBounds: CGRect, scannedBounds: CGRect,
                          timestamp: TimeInterval) -> Bool {
        guard let failedAt = since[displayID], timestamp >= failedAt,
              !scannedBounds.isNull, scannedBounds.contains(displayBounds) else { return false }
        since.removeValue(forKey: displayID)
        return true
    }

    mutating func reset() { since.removeAll() }
}
