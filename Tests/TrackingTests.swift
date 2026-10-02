import Foundation
import Darwin
import CoreGraphics

struct Canvas {
    let width = 1280, height = 720
    var bytes = [UInt8](repeating: 245, count: 1280 * 720)
    mutating func text(x: Int, y: Int, seed: UInt64, width: Int = 120, height: Int = 18) {
        var state = seed
        for col in 0..<(width / 6) {
            state = state &* 6364136223846793005 &+ 1
            for gy in 0..<9 {
                for gx in 0..<4 {
                    let bit = (state >> UInt64((gy * 4 + gx) % 61)) & 1
                    if bit == 0 { continue }
                    for sy in 0..<2 {
                        let px = x + col * 6 + gx, py = y + gy * 2 + sy
                        guard px >= 0, py >= 0, px < width + x, px < self.width, py < self.height else { continue }
                        bytes[py * self.width + px] = UInt8(20 + (col * 13 + gy) % 35)
                    }
                }
            }
        }
    }
    var frame: GrayFrame { GrayFrame(width: width, height: height, bytes: bytes) }
}

func near(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat = 1) -> Bool {
    abs(actual.minX - expected.minX) <= tolerance && abs(actual.minY - expected.minY) <= tolerance && actual.size == expected.size
}
func rect(_ x: Int, _ y: Int) -> CGRect { CGRect(x: x, y: y, width: 120, height: 18) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main struct TrackingTests {
    static func main() {
        setbuf(stdout, nil)
        var source = Canvas(); source.text(x: 300, y: 250, seed: 31)
        let tracker = TextMaskTracker()
        tracker.seed(boxes: [TextTrackBox(id: 1, rect: rect(300, 250))], in: source.frame, at: 0)
        var moved = Canvas(); moved.text(x: 309, y: 213, seed: 31)
        var result = tracker.track(in: moved.frame, at: 1)
        require(result.count == 1 && near(result[0].rect, rect(309, 213)), "translation +x/-y")
        var next = Canvas(); next.text(x: 286, y: 266, seed: 31)
        result = tracker.track(in: next.frame, at: 1.03)
        require(result.count == 1 && near(result[0].rect, rect(286, 266)), "translation -x/+y")

        var chrome = Canvas(); chrome.text(x: 500, y: 30, seed: 33); chrome.text(x: 300, y: 250, seed: 31)
        tracker.seed(boxes: [TextTrackBox(id: 1, rect: rect(300, 250)), TextTrackBox(id: 2, rect: rect(500, 30))], in: chrome.frame, at: 2)
        var scrolled = Canvas(); scrolled.text(x: 500, y: 30, seed: 33); scrolled.text(x: 300, y: 205, seed: 31)
        result = tracker.track(in: scrolled.frame, at: 2.03)
        require(result.count == 2, "stable chrome and moving text")
        require(near(result.first { $0.id == 1 }!.rect, rect(300, 205)), "local moving text")
        require(near(result.first { $0.id == 2 }!.rect, rect(500, 30)), "chrome must not shift")

        tracker.seed(boxes: [TextTrackBox(id: 1, rect: rect(300, 250))], in: source.frame, at: 3)
        var jumped = Canvas(); jumped.text(x: 800, y: 250, seed: 31)
        require(tracker.track(in: jumped.frame, at: 3.03).isEmpty, "large jump must not invent mask")
        require(tracker.track(in: Canvas().frame, at: 3.3).isEmpty, "lost target expiry")
        require(tracker.track(in: source.frame, at: 3.4).isEmpty, "expired target must not revive")

        tracker.seed(boxes: [TextTrackBox(id: 1, rect: rect(300, 250))], in: source.frame, at: 4)
        var duplicate = Canvas(); duplicate.text(x: 300, y: 210, seed: 31); duplicate.text(x: 300, y: 290, seed: 31)
        require(tracker.track(in: duplicate.frame, at: 4.03).isEmpty, "ambiguous repeated text must not jump")

        tracker.seed(boxes: [TextTrackBox(id: 1, rect: rect(300, 250))], in: source.frame, at: 5)
        var occluded = source
        for y in 246..<274 { for x in 340..<426 { occluded.bytes[y * 1280 + x] = 130 } }
        require(tracker.track(in: occluded.frame, at: 5.03).isEmpty, "occluded secret must not create broad mask")
        result = tracker.track(in: source.frame, at: 5.06)
        require(result.count == 1 && result[0].rect == rect(300, 250), "short loss can reacquire")
        require(tracker.track(in: source.frame, at: 5.01).isEmpty, "stale frame rejected")
        tracker.seed(boxes: [], in: source.frame, at: 6)
        require(tracker.track(in: source.frame, at: 6.03).isEmpty, "empty seed clears targets")

        var many = Canvas()
        var boxes: [TextTrackBox] = []
        for i in 0..<8 {
            let x = 180 + (i % 2) * 580, y = 130 + (i / 2) * 135
            many.text(x: x, y: y, seed: UInt64(31 + i * 777))
            boxes.append(TextTrackBox(id: i, rect: rect(x,y)))
        }
        let fast = TextMaskTracker()
        fast.seed(boxes: boxes, in: many.frame, at: 10)
        var samples: [Double] = []
        for iteration in 0..<50 {
            let dx = iteration % 2 == 0 ? 5 : -4, dy = iteration % 2 == 0 ? -13 : 9
            var frame = Canvas()
            for box in boxes { frame.text(x: Int(box.rect.minX) + dx, y: Int(box.rect.minY) + dy, seed: UInt64(31 + box.id * 777)) }
            let begin = ProcessInfo.processInfo.systemUptime
            let matches = fast.track(in: frame.frame, at: 10.03 + Double(iteration) / 30)
            let elapsed = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            require(matches.count == 8, "all benchmark targets tracked at iteration \(iteration): \(matches.count)")
            if iteration > 0 { samples.append(elapsed) } else { print(String(format: "initial wide alignment %.2fms", elapsed)) }
            for match in matches { require(match.rect.size == boxes[match.id].rect.size, "mask must never grow") }
        }
        samples.sort()
        print(String(format:"8 targets, 1280x720: median %.2fms p95 %.2fms max %.2fms", samples[samples.count/2], samples[Int(Double(samples.count-1)*0.95)], samples.last!))
        print("all local tracking tests passed")
    }
}
