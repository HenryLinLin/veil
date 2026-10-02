import Foundation
import CoreGraphics

struct ContentChanges {
    private var latest: [CGWindowID: TimeInterval] = [:]

    mutating func changed(windowID: CGWindowID, at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        latest[windowID] = max(latest[windowID] ?? -.infinity, timestamp)
    }

    func accepts(windowID: CGWindowID, timestamp: TimeInterval) -> Bool {
        timestamp >= (latest[windowID] ?? -.infinity)
    }

    mutating func retain(windowIDs: Set<CGWindowID>) {
        latest = latest.filter { windowIDs.contains($0.key) }
    }

    mutating func reset() { latest.removeAll() }
}
