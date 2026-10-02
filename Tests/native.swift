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
        scrollProtectionChecks()
        scanFailureChecks()
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

    static func scrollProtectionChecks() {
        let owner = window()
        let display = CGRect(x: 0, y: 0, width: 1000, height: 700)
        var protection = ScrollProtection()
        protection.scrolled(windowID: owner.id, at: 10)
        protection.scrolled(windowID: owner.id, at: 10.02)
        protection.scanned(bounds: display, timestamp: 10.13)
        expect(protection.update(windows: [owner], displays: [display], now: 10.2).isEmpty,
               "closely spaced scroll events each restart the quiet interval")
        expect(!protection.accepts(windowID: owner.id, timestamp: 10.13),
               "high-frequency scrolling advances the frame eligibility cutoff")
        protection.scanned(bounds: display, timestamp: 10.15)
        expect(protection.update(windows: [owner], displays: [display], now: 10.2) == [owner.id],
               "a scan after the final high-frequency event's quiet interval releases")
        protection.reset()
        protection.scrolled(windowID: owner.id, at: 60)
        protection.scanned(bounds: display, timestamp: 59.9)
        expect(protection.update(windows: [owner], displays: [display], now: 60.3).isEmpty,
               "an OCR frame from before scrolling cannot release the guard")
        expect(protection.windowIDs == [owner.id], "an old scan leaves the window guarded")
        expect(!protection.accepts(windowID: owner.id, timestamp: 59.9), "old frame geometry is not accepted while guarded")

        protection.reset()
        protection.scrolled(windowID: owner.id, at: 70)
        protection.scanned(bounds: display, timestamp: 70.01)
        expect(protection.update(windows: [owner], displays: [display], now: 70.11).isEmpty,
               "the quiet interval is required even after a complete scan")
        expect(protection.update(windows: [owner], displays: [display], now: 70.3).isEmpty,
               "waiting after an in-motion frame does not make its old coverage settled")
        protection.scanned(bounds: display, timestamp: 70.13)
        expect(protection.update(windows: [owner], displays: [display], now: 70.3) == [owner.id],
               "a full scan captured after the quiet interval releases the window")

        protection.scrolled(windowID: owner.id, at: 80)
        protection.scanned(bounds: display, timestamp: 80.13)
        expect(protection.update(windows: [owner], displays: [display], now: 80.14) == [owner.id],
               "a stable scanned window initially releases")
        protection.scrolled(windowID: owner.id, at: 80.2)
        protection.scanned(bounds: display, timestamp: 80.13)
        expect(protection.update(windows: [owner], displays: [display], now: 80.5).isEmpty,
               "renewed scrolling invalidates previously verified coverage")
        protection.scrolled(windowID: owner.id, at: 80.1)
        expect(!protection.accepts(windowID: owner.id, timestamp: 80.15),
               "an out-of-order scroll event cannot move the content cutoff backwards")
        protection.scanned(bounds: display, timestamp: 80.33)
        expect(protection.update(windows: [owner], displays: [display], now: 80.5) == [owner.id],
               "the renewed scroll requires its own post-quiet scan")

        let straddling = window(1, CGRect(x: 50, y: 0, width: 100, height: 100))
        let screens = [CGRect(x: 0, y: 0, width: 100, height: 100),
                       CGRect(x: 100, y: 0, width: 100, height: 100)]
        protection.reset()
        protection.scrolled(windowID: straddling.id, at: 90)
        protection.scanned(bounds: screens[0], timestamp: 90.13)
        expect(protection.update(windows: [straddling], displays: screens, now: 90.3).isEmpty,
               "scanning one display does not release a window spanning two displays")
        protection.scanned(bounds: CGRect(x: 101, y: 0, width: 99, height: 100), timestamp: 90.14)
        expect(protection.update(windows: [straddling], displays: screens, now: 90.3).isEmpty,
               "partial multi-display coverage cannot leave an unverified strip")
        protection.scanned(bounds: CGRect(x: 100, y: 0, width: 1, height: 100), timestamp: 90.15)
        expect(protection.update(windows: [straddling], displays: screens, now: 90.3) == [straddling.id],
               "the union of post-quiet display scans must cover the whole visible window")

        protection.reset()
        protection.scrolled(windowID: owner.id, at: 100)
        protection.accessibilityScanned(windowIDs: [owner.id], startedAt: 99.9)
        expect(protection.update(windows: [owner], displays: [display], now: 100.3).isEmpty,
               "an AX scan begun before scrolling cannot release the guard")
        protection.accessibilityScanned(windowIDs: [owner.id], startedAt: 100.01)
        expect(protection.update(windows: [owner], displays: [display], now: 100.3).isEmpty,
               "an AX scan begun during the quiet interval cannot certify settled content")
        protection.accessibilityScanned(windowIDs: [owner.id], startedAt: 100.13)
        expect(protection.update(windows: [owner], displays: [display], now: 100.3) == [owner.id],
               "a completed AX scan begun after the quiet interval releases AX-only protection")

        protection.scrolled(windowID: owner.id, at: 110)
        expect(protection.update(windows: [], displays: [display], now: 110.01) == [owner.id],
               "closed windows immediately drop their pending guards")
        expect(protection.windowIDs.isEmpty, "closed windows do not leave stuck guards")
        expect(protection.accepts(windowID: owner.id, timestamp: 109),
               "closing a window forgets its cutoff before an ID is reused")

        protection.scrolled(windowID: owner.id, at: 120)
        protection.scanned(bounds: display, timestamp: 120.13)
        _ = protection.update(windows: [owner], displays: [display], now: 120.3)
        expect(!protection.accepts(windowID: owner.id, timestamp: 119.9),
               "releasing a guard does not make delayed pre-scroll frames eligible")
        expect(!protection.accepts(windowID: owner.id, timestamp: 120.01),
               "releasing a guard does not make delayed in-motion frames eligible")
        expect(protection.accepts(windowID: owner.id, timestamp: 120.13),
               "post-scroll frames remain eligible after release")
        expect(protection.accepts(windowID: 2, timestamp: 119.9),
               "scrolling one window does not invalidate unrelated window content")
        protection.reset()
        expect(protection.windowIDs.isEmpty && protection.accepts(windowID: owner.id, timestamp: 119.9),
               "reset clears both guards and historical content cutoffs")
    }
    static func scanFailureChecks() {
        var failures = ScanFailures()
        let display = CGRect(x: -400, y: 0, width: 400, height: 300)
        failures.failed(displayID: 1, at: 10)
        failures.failed(displayID: 2, at: 10)
        expect(!failures.scanned(displayID: 1, displayBounds: display, scannedBounds: display, timestamp: 9), "old full scans cannot clear a later detector failure")
        expect(!failures.scanned(displayID: 1, displayBounds: display, scannedBounds: CGRect(x: -400, y: 0, width: 400, height: 100), timestamp: 11), "partial OCR bands cannot uncover a failed display")
        expect(!failures.scanned(displayID: 1, displayBounds: display, scannedBounds: .null, timestamp: 11), "empty OCR work cannot clear failure coverage")
        expect(failures.scanned(displayID: 1, displayBounds: display, scannedBounds: display, timestamp: 11), "new full scans restore a protected display")
        expect(failures.since[1] == nil && failures.since[2] != nil, "one recovered display cannot clear another display's failure")
        failures.failed(displayID: 2, at: 12)
        failures.failed(displayID: 2, at: 9)
        expect(!failures.scanned(displayID: 2, displayBounds: display, scannedBounds: display, timestamp: 11), "late failures cannot move the recovery boundary backward")
        failures.reset()
        expect(failures.since.isEmpty, "stopping clears failure coverage")
    }

}
