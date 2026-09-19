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
}
