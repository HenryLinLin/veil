import AppKit
import CoreImage
import Metal

enum FeedChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func sample(width: Int = 100, height: Int = 80) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func run() throws -> [String] {
        var results: [String] = []
        let source = sample()
        var buffer = DelayedFeedBuffer()
        try check(buffer.enqueue(source, at: 0, delay: 0.5), "First delayed frame rejected")
        try check(buffer.ready(at: 0.499) == nil, "Frame escaped before its delay")
        try check(buffer.ready(at: 0.5) != nil, "Frame was not released at its deadline")
        try check(buffer.count == 0, "Released frame retained in queue")

        for delay in [0.0, 0.5, 1.5, 2.0] {
            var queue = DelayedFeedBuffer()
            _ = queue.setDelay(delay)
            var arrivals: [(CGImage, Double)] = []
            var released = 0
            for tick in 0...800 {
                let now = Double(tick) / 100
                if let image = queue.ready(at: now) {
                    guard let arrival = arrivals.first(where: { ObjectIdentifier($0.0) == ObjectIdentifier(image) })?.1 else {
                        throw Failure(description: "Queue emitted an unknown image")
                    }
                    try check(now - arrival >= delay - 0.000001, "Queue shortened the configured delay")
                    released += 1
                }
                if queue.canAccept(at: now) {
                    let frame = sample(width: 2, height: 2)
                    if queue.enqueue(frame, at: now, delay: delay) { arrivals.append((frame, now)) }
                }
                try check(queue.count <= 6, "Queue exceeded six frames")
            }
            try check(released >= 10, "High input rate starved delayed output")
        }

        var full = DelayedFeedBuffer()
        for index in 0..<6 {
            try check(full.enqueue(source, at: Double(index) * 0.401, delay: 2), "Queue filled prematurely")
        }
        try check(!full.enqueue(source, at: 3, delay: 2), "Full queue accepted extra frame")
        try check(full.ready(at: 2) != nil, "Overflow discarded the oldest delayed frame")
        _ = full.setDelay(1.5)
        try check(full.count == 0 && full.ready(at: 20) == nil, "Delay change retained prior frames")
        _ = full.setDelay(.infinity)
        try check(full.currentDelay == 2, "Invalid delay did not use the conservative maximum")
        _ = full.setDelay(-1)
        try check(full.currentDelay == 0, "Negative delay was not bounded")
        full.clear()
        try check(full.canAccept(at: 0), "Clear retained stale admission timestamps")
        results.append("delay deadlines, adaptive admission, queue bounds and resets")
        try holdChecks()
        results.append("held playback, discarded pending frames, delayed recovery and explicit reset")

        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"emails":true}"#.utf8))
        try check(old.emails && old.known && old.generic && old.personal && old.ocr,
                  "Old preferences lost new-field defaults")
        try check(old.mode == "overlay" && old.delay == 0.5 && old.presentKey == 35 && old.peekKey == 9,
                  "Old preferences lost control defaults")
        try check(!old.windowRules.isEmpty && old.allowedHashes.isEmpty && !old.ruleUpdates,
                  "Old preferences lost privacy defaults")
        var configured = old
        configured.customRules = [CustomRule(id: "example", pattern: "example-[a-z]+", score: 0.9)]
        configured.allowedHashes = [String(repeating: "a", count: 64)]
        configured.allowedPaths = ["/tmp/example.txt"]
        configured.disabledRules = ["example-disabled"]
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(configured))
        try check(restored.customRules.first?.score == 0.9 && restored.allowedHashes == configured.allowedHashes,
                  "Preferences round trip changed rule or hash values")
        try check(restored.allowedPaths == configured.allowedPaths && restored.disabledRules == configured.disabledRules,
                  "Preferences round trip changed allowlist values")
        results.append("backward-compatible preferences and JSON round trip")

        let software = FeedCompositor(context: CIContext(options: [.useSoftwareRenderer: true]))
        try renderingChecks(software)
        results.append("software opacity, padding, mask orientation and output dimensions")

        let compositor = FeedCompositor()
        guard MTLCreateSystemDefaultDevice() != nil else {
            try check(compositor.redact(source, masks: []) == nil, "Compositor did not fail closed without Metal")
            results.append("no-Metal fail-closed behavior; GPU pixel checks skipped")
            return results
        }
        try renderingChecks(compositor)
        results.append("Metal opacity, padding, mask orientation and output dimensions")
        return results
    }

    private static func holdChecks() throws {
        let first = sample()
        let pending = sample()
        let resumed = sample()
        var playback = FeedPlayback()
        try check(playback.publish(first, at: 0, delay: 0.5), "Initial protected frame rejected")
        playback.tick(at: 0.5)
        try check(playback.image === first, "Initial protected frame was not displayed")
        try check(playback.publish(pending, at: 0.6, delay: 0.5), "Pending protected frame rejected")
        try check(playback.pendingCount == 1 && playback.image === first,
                  "A pending delayed frame replaced the displayed image early")
        playback.hold()
        try check(playback.pendingCount == 0 && playback.isHeld && playback.image === first,
                  "Hold did not discard pending frames while retaining the displayed image")
        playback.tick(at: 100)
        try check(playback.image === first && playback.isHeld,
                  "Stale-input expiry erased an explicitly held protected frame")
        playback.hold()
        try check(playback.image === first && playback.pendingCount == 0, "Repeated hold changed the displayed frame")
        try check(playback.publish(resumed, at: 100, delay: 0.5), "Verified frame could not resume held playback")
        try check(!playback.isHeld && playback.image === first && playback.pendingCount == 1,
                  "Resuming did not preserve the frozen frame during the new delay")
        playback.tick(at: 100.499)
        try check(playback.image === first, "Recovery shortened the configured delay")
        playback.tick(at: 100.5)
        try check(playback.image === resumed && playback.image !== pending,
                  "Recovery displayed a discarded pending frame")
        playback.clear()
        try check(playback.image == nil && playback.pendingCount == 0 && !playback.isHeld,
                  "Explicit clear retained held playback state")

        var waiting = FeedPlayback()
        _ = waiting.publish(first, at: 0, delay: 0.5)
        waiting.hold()
        waiting.tick(at: 100)
        try check(waiting.image == nil && waiting.pendingCount == 0 && waiting.isHeld,
                  "Holding before first display exposed a pending frame")
        _ = waiting.publish(resumed, at: 101, delay: 0)
        try check(waiting.image === resumed && !waiting.isHeld,
                  "Zero-delay verified recovery did not display immediately")

        var idle = FeedPlayback()
        idle.tick(at: 0)
        try check(idle.image == nil && !idle.isHeld, "An empty new feed incorrectly began paused")
        _ = idle.publish(first, at: 0, delay: 0)
        idle.tick(at: 2.01)
        try check(idle.isHeld && idle.image === first && idle.pendingCount == 0,
                  "Idle input erased the last protected image instead of holding it")
        idle.tick(at: 100)
        try check(idle.image === first, "A long idle interval erased the held image")
        _ = idle.publish(resumed, at: 100, delay: 0)
        try check(!idle.isHeld && idle.image === resumed, "Verified input did not resume an idle feed")
    }

    private static func renderingChecks(_ compositor: FeedCompositor) throws {
        let source = sample()
        guard let protected = compositor.redact(source, masks: [CGRect(x: 30, y: 10, width: 20, height: 10)]),
              let provider = protected.dataProvider?.data else {
            throw Failure(description: "Compositor did not return a protected image")
        }
        let pixels = provider as Data
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let start = y * protected.bytesPerRow + x * 4
            return Array(pixels[start..<(start + 4)])
        }
        let blocked = pixel(40, 15)
        let padded = pixel(28, 8)
        let clear = pixel(40, 65)
        try check(blocked[0] < 64 && blocked[1] < 64 && blocked[2] < 64 && blocked[3] == 255,
                  "Mask pixels are not dark and fully opaque")
        try check(padded[0] < 64 && padded[3] == 255, "Mask padding is missing")
        try check(clear[0] > 230 && clear[1] < 10 && clear[2] < 10 && clear[3] == 255,
                  "Unmasked pixel has the wrong color or position: \(clear)")
        try check(compositor.redact(source, masks: [CGRect(x: CGFloat.infinity, y: 1, width: 4, height: 4)]) == nil,
                  "Nonfinite mask did not fail closed")
        guard let reduced = compositor.redact(sample(width: 3200, height: 100), masks: []) else {
            throw Failure(description: "Large image compositing failed")
        }
        try check(reduced.width <= 1600 && reduced.height <= 1000, "Sanitized queue image exceeded its size bound")
    }
}

#if FEED_TEST_MAIN
@main
enum FeedTests {
    static func main() {
        do {
            for result in try FeedChecks.run() { print("ok: \(result)") }
        } catch {
            FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8))
            exit(1)
        }
    }
}
#endif
