import AppKit

@main
enum NativeTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            exit(1)
        }
    }

    static func window(_ id: UInt32 = 1, _ bounds: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300)) -> ScreenWindow {
        ScreenWindow(id: id, pid: 99, app: "test.editor", title: "example", bounds: bounds, layer: 0)
    }

    static func mask(_ rect: CGRect, hash: String = "a", windowID: UInt32 = 1) -> Mask {
        Mask(rect: rect, rule: "github-token", app: "test.editor", hash: hash, windowID: windowID)
    }

    static func area(_ rects: [CGRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        return !overlap.isNull && !overlap.isEmpty
    }

    static func main() {
        subtraction()
        occlusion()
        tracking()
        overlappingTokens()
        partialOverlapHold()
        sameIdentityCoverage()
        invalidateScrolledWindows()
        contentChangeChecks()
        resizingStaysLocal()
        print("\(checks) native geometry and tracking checks passed")
    }

    static func subtraction() {
        let base = CGRect(x: -100, y: -50, width: 200, height: 100)
        expect(subtract(base, CGRect(x: 500, y: 500, width: 5, height: 5)) == [base], "disjoint cover preserves the rectangle")
        expect(subtract(base, base).isEmpty, "complete cover removes the rectangle")
        expect(subtract(base, CGRect(x: 100, y: -50, width: 5, height: 100)) == [base], "touching edges do not remove pixels")
        for x in stride(from: -150, through: 150, by: 25) {
            for y in stride(from: -100, through: 100, by: 25) {
                let cover = CGRect(x: x, y: y, width: 60, height: 40)
                let parts = subtract(base, cover)
                let cut = base.intersection(cover)
                let removed = cut.isNull ? 0 : cut.width * cut.height
                expect(abs(area(parts) - (base.width * base.height - removed)) < 0.001, "subtraction preserves the exact remaining area")
                expect(parts.allSatisfy { base.contains($0) }, "subtraction stays inside the source")
                expect(parts.allSatisfy { !overlaps($0, cover) }, "remaining pixels are outside the cover")
                for i in parts.indices {
                    for j in parts.indices where i < j {
                        expect(!overlaps(parts[i], parts[j]), "subtraction parts do not overlap")
                    }
                }
            }
        }
    }

    static func occlusion() {
        let back = window(1, CGRect(x: -200, y: 30, width: 200, height: 100))
        let front = window(2, CGRect(x: -150, y: 30, width: 50, height: 100))
        let parts = back.visibleParts(of: back.bounds, in: [front, back])
        expect(area(parts) == 15_000, "front window subtracts its covered area")
        expect(parts.allSatisfy { !overlaps($0, front.bounds) }, "front window never receives a background mask")
        expect(back.visibleParts(of: back.bounds, in: [back, front]) == [back.bounds], "windows behind the owner do not occlude it")
        let outside = CGRect(x: -250, y: 0, width: 400, height: 200)
        expect(back.visibleParts(of: outside, in: [back]) == [back.bounds], "text masks clip to their owner window")
    }

    static func tracking() {
        let tracker = MaskTracker()
        let old = window()
        let rect = CGRect(x: 30, y: 40, width: 100, height: 20)
        expect(tracker.update([mask(rect)], windows: [old], now: 10).count == 1, "fresh detection appears immediately")
        let moved = window(1, old.bounds.offsetBy(dx: -60, dy: 80))
        let next = tracker.update([], windows: [moved], now: 10.1)
        expect(next.first?.rect == rect.offsetBy(dx: -60, dy: 80), "held masks follow window moves across display origins")
        let front = window(2, CGRect(x: -30, y: 120, width: 50, height: 20))
        let clipped = tracker.update([], windows: [front, moved], now: 10.2)
        expect(area(clipped.map(\.rect)) == 1000, "tracked masks respect newly occluding windows")
        expect(tracker.update([], windows: [moved], now: 10.5).isEmpty, "stale detection expires at the hysteresis boundary")
        _ = tracker.update([mask(rect)], windows: [old], now: 11)
        expect(tracker.update([], windows: [], now: 11.1).isEmpty, "closing an owner clears its mask")
        _ = tracker.update([mask(rect, windowID: 0)], windows: [], now: 12)
        expect(tracker.update([], windows: [], now: 12.1).count == 1, "unowned OCR masks remain for the short hold interval")
        tracker.reset()
        var anchored = mask(rect)
        anchored.anchor = old.bounds
        let shifted = tracker.update([anchored], windows: [moved], now: 12.15)
        expect(shifted.first?.rect == rect.offsetBy(dx: -60, dy: 80), "fresh cached detections follow their original window anchor")
        tracker.reset()
        expect(tracker.update([], windows: [], now: 12.2).isEmpty, "disarming clears all held masks")
    }

    static func overlappingTokens() {
        let tracker = MaskTracker()
        let owner = window()
        let left = mask(CGRect(x: 10, y: 10, width: 100, height: 24), hash: "left")
        let right = mask(CGRect(x: 105, y: 10, width: 100, height: 24), hash: "right")
        let masks = tracker.update([left, right], windows: [owner], now: 20)
        expect(masks.contains { $0.rect.contains(CGPoint(x: 15, y: 15)) }, "overlapping padding never erases the first secret")
        expect(masks.contains { $0.rect.contains(CGPoint(x: 200, y: 15)) }, "overlapping padding retains the second secret")
        let renewed = tracker.update([left, right], windows: [owner], now: 20.1)
        expect(renewed.count <= 2, "refreshes do not accumulate duplicate masks")
    }

    static func partialOverlapHold() {
        let tracker = MaskTracker()
        let owner = window()
        var first = mask(CGRect(x: 10, y: 10, width: 100, height: 24), hash: "first-value")
        var second = mask(CGRect(x: 10, y: 30, width: 100, height: 24), hash: "second-value")
        first.rule = "ssn"
        second.rule = "ssn"
        _ = tracker.update([first, second], windows: [owner], now: 30)
        let next = tracker.update([second], windows: [owner], now: 30.1)
        let firstOnly = CGPoint(x: 15, y: 15)
        expect(next.contains { $0.hash == first.hash && $0.rect.contains(firstOnly) },
               "a different SSN with overlapping padding does not erase the held value")
        expect(next.count == 2, "the refreshed value replaces only its own fully covered mask")
        let held = tracker.update([], windows: [owner], now: 30.499)
        expect(held.contains { $0.rect.contains(firstOnly) }, "a missed value remains covered until its original expiry")
        let expired = tracker.update([], windows: [owner], now: 30.5)
        expect(!expired.contains { $0.rect.contains(firstOnly) }, "overlap does not extend the missed value's expiry")
        expect(expired.contains { $0.hash == second.hash }, "the later refreshed value retains its own expiry")
    }

    static func sameIdentityCoverage() {
        let tracker = MaskTracker()
        let owner = window()
        let wide = mask(CGRect(x: 10, y: 10, width: 100, height: 24))
        let narrow = mask(CGRect(x: 50, y: 10, width: 60, height: 24))
        _ = tracker.update([wide], windows: [owner], now: 40)
        let partial = tracker.update([narrow], windows: [owner], now: 40.1)
        expect(partial.contains { $0.rect.contains(CGPoint(x: 15, y: 15)) },
               "partial same-value geometry does not reveal the uncovered old area")
        let expanded = mask(CGRect(x: 5, y: 5, width: 120, height: 40))
        let covered = tracker.update([expanded], windows: [owner], now: 40.2)
        expect(covered.count == 1 && covered.first?.rect == expanded.rect,
               "the same identity can replace every fully covered held mask")
        expect(tracker.update([expanded], windows: [owner], now: 40.3).count == 1,
               "identical fully covering refreshes do not accumulate")
    }

    static func invalidateScrolledWindows() {
        let tracker = MaskTracker()
        let first = window()
        let second = window(2, CGRect(x: 500, y: 0, width: 400, height: 300))
        let owners = [first, second]
        let firstMask = mask(CGRect(x: 10, y: 20, width: 50, height: 10))
        let secondMask = mask(CGRect(x: 510, y: 20, width: 50, height: 10), windowID: 2)
        let unowned = mask(CGRect(x: -50, y: -50, width: 10, height: 10), windowID: 0)
        _ = tracker.update([firstMask, secondMask, unowned], windows: owners, now: 50)
        tracker.invalidate(windowIDs: [first.id])
        let kept = tracker.update([], windows: owners, now: 50.1)
        expect(!kept.contains { $0.windowID == first.id }, "scroll invalidation drops that window's held geometry immediately")
        expect(kept.contains { $0.windowID == second.id }, "scroll invalidation preserves other windows")
        expect(kept.contains { $0.windowID == 0 }, "scroll invalidation preserves unowned masks unless explicitly requested")
        tracker.invalidate(windowIDs: [])
        expect(tracker.update([], windows: owners, now: 50.15).count == 2, "an empty invalidation preserves all held masks")
        let renewed = tracker.update([firstMask], windows: owners, now: 50.2)
        expect(renewed.contains { $0.windowID == first.id }, "a new scan can protect an invalidated window again")
        tracker.invalidate(windowIDs: [first.id, second.id])
        let remainder = tracker.update([], windows: owners, now: 50.3)
        expect(remainder.count == 1 && remainder.first?.windowID == 0, "multiple scrolling windows invalidate together")
        tracker.invalidate(windowIDs: [0])
        expect(tracker.update([], windows: owners, now: 50.4).isEmpty, "unowned masks can be explicitly invalidated")
    }

    static func contentChangeChecks() {
        var changes = ContentChanges()
        changes.changed(windowID: 1, at: 10)
        expect(!changes.accepts(windowID: 1, timestamp: 9), "old accessibility rectangles cannot be reused after scrolling")
        expect(changes.accepts(windowID: 1, timestamp: 10.01), "fresh detections are usable during continuous scrolling")
        expect(changes.accepts(windowID: 2, timestamp: 9), "unrelated windows keep their detections")
        changes.changed(windowID: 1, at: 8)
        expect(!changes.accepts(windowID: 1, timestamp: 9), "out-of-order events cannot restore stale rectangles")
        changes.retain(windowIDs: [])
        expect(changes.accepts(windowID: 1, timestamp: 9), "closing a window resets reused IDs")
        changes.changed(windowID: 1, at: 12)
        changes.reset()
        expect(changes.accepts(windowID: 1, timestamp: 9), "stopping clears content epochs")
    }
    static func resizingStaysLocal() {
        let tracker = MaskTracker()
        let original = window()
        let resized = window(1, CGRect(x: 0, y: 0, width: 600, height: 500))
        var token = mask(CGRect(x: 20, y: 30, width: 100, height: 20))
        token.anchor = original.bounds
        _ = tracker.update([token], windows: [original], now: 1)
        expect(tracker.update([], windows: [resized], now: 1.1).isEmpty,
               "window resizing never expands a held text mask into a blanket")
        expect(tracker.update([token], windows: [resized], now: 1.2).isEmpty,
               "cached text geometry cannot become a whole-window mask after resizing")
        token.anchor = resized.bounds
        let refreshed = tracker.update([token], windows: [resized], now: 1.3)
        expect(refreshed.count == 1 && refreshed[0].rect == token.rect,
               "a new localized scan restores the small mask after resizing")
    }

}
