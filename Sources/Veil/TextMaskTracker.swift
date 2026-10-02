import Foundation
import CoreGraphics

struct GrayFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    var isValid: Bool {
        width > 0 && height > 0 && width <= 16_384 && height <= 16_384 && bytes.count == width * height
    }

    fileprivate func quarterSize() -> GrayFrame {
        let w = max(1, width / 4), h = max(1, height / 4)
        var output = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0, count = 0
                for dy in 0..<4 where y * 4 + dy < height {
                    let row = (y * 4 + dy) * width
                    for dx in 0..<4 where x * 4 + dx < width {
                        sum += Int(bytes[row + x * 4 + dx])
                        count += 1
                    }
                }
                output[y * w + x] = UInt8(sum / max(1, count))
            }
        }
        return GrayFrame(width: w, height: h, bytes: output)
    }
}

struct TextTrackBox {
    let id: Int
    let rect: CGRect
}

struct TrackedTextBox {
    let id: Int
    let rect: CGRect
    let confidence: Double
}

final class TextMaskTracker {
    private struct Point {
        let x: Int
        let y: Int
        let value: Double
    }
    private struct Descriptor {
        let points: [Point]
        let sum: Double
        let variance: Double
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
    }
    private struct Target {
        let id: Int
        var rect: CGRect
        let fine: Descriptor
        let coarse: Descriptor
        var lastSeen: TimeInterval
        var initial = true
    }
    private struct Candidate {
        let x: Int
        let y: Int
        let score: Double
    }

    private let searchRadius: Int
    private let initialSearchRadius: Int
    private let minimumConfidence: Double
    private let ambiguityMargin: Double
    private let lostLifetime: TimeInterval
    private let maximumTargets: Int
    private var targets: [Target] = []
    private var frameSize: (Int, Int)?
    private var lastTimestamp: TimeInterval = -.infinity

    init(searchRadius: Int = 96, initialSearchRadius: Int = 256,
         minimumConfidence: Double = 0.80, ambiguityMargin: Double = 0.035,
         lostLifetime: TimeInterval = 0.18, maximumTargets: Int = 32) {
        self.searchRadius = max(4, min(512, searchRadius))
        self.initialSearchRadius = max(4, min(512, initialSearchRadius))
        self.minimumConfidence = minimumConfidence
        self.ambiguityMargin = ambiguityMargin
        self.lostLifetime = max(0, lostLifetime)
        self.maximumTargets = max(1, min(32, maximumTargets))
    }

    func reset() {
        targets.removeAll()
        frameSize = nil
        lastTimestamp = -.infinity
    }

    func seed(boxes: [TextTrackBox], in frame: GrayFrame, at timestamp: TimeInterval) {
        reset()
        guard frame.isValid, timestamp.isFinite else { return }
        frameSize = (frame.width, frame.height)
        lastTimestamp = timestamp
        let coarse = frame.quarterSize()
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        var ids = Set<Int>()
        for box in boxes.prefix(maximumTargets) {
            guard ids.insert(box.id).inserted, box.rect.width >= 3, box.rect.height >= 3,
                  !box.rect.isNull, bounds.contains(box.rect) else { continue }
            let anchorX = Int(floor(box.rect.minX)), anchorY = Int(floor(box.rect.minY))
            let patch = box.rect.insetBy(dx: -8, dy: -6).intersection(bounds).integral
            guard let fine = descriptor(frame, patch: patch, anchorX: anchorX, anchorY: anchorY, samples: 144),
                  let small = descriptor(coarse, patch: CGRect(x: patch.minX / 4, y: patch.minY / 4,
                                                               width: patch.width / 4, height: patch.height / 4),
                                         anchorX: anchorX / 4, anchorY: anchorY / 4, samples: 48) else { continue }
            targets.append(Target(id: box.id, rect: box.rect, fine: fine, coarse: small, lastSeen: timestamp))
        }
    }

    func track(in frame: GrayFrame, at timestamp: TimeInterval) -> [TrackedTextBox] {
        guard frame.isValid, let size = frameSize, size.0 == frame.width, size.1 == frame.height,
              timestamp.isFinite, timestamp >= lastTimestamp else { return [] }
        lastTimestamp = timestamp
        let coarse = frame.quarterSize()
        var result: [TrackedTextBox] = []
        var retained: [Target] = []
        for var target in targets {
            let x = Int(floor(target.rect.minX)), y = Int(floor(target.rect.minY))
            let stationary = score(target.fine, in: frame, x: x, y: y)
            let found: Candidate?
            if stationary >= 0.995 {
                found = Candidate(x: x, y: y, score: stationary)
            } else {
                found = locate(target, frame: frame, coarse: coarse,
                               radius: target.initial ? initialSearchRadius : searchRadius)
            }
            if let found {
                target.rect = target.rect.offsetBy(dx: CGFloat(found.x - x), dy: CGFloat(found.y - y))
                target.lastSeen = timestamp
                target.initial = false
                retained.append(target)
                result.append(TrackedTextBox(id: target.id, rect: target.rect, confidence: found.score))
            } else if target.initial || timestamp - target.lastSeen <= lostLifetime {
                target.initial = false
                retained.append(target)
            }
        }
        targets = retained
        return result
    }

    private func locate(_ target: Target, frame: GrayFrame, coarse: GrayFrame, radius: Int) -> Candidate? {
        let oldX = Int(floor(target.rect.minX)), oldY = Int(floor(target.rect.minY))
        let centerX = oldX / 4, centerY = oldY / 4
        let coarseRadius = (radius + 3) / 4
        var peaks: [Candidate] = []
        for y in (centerY - coarseRadius)...(centerY + coarseRadius) {
            for x in (centerX - coarseRadius)...(centerX + coarseRadius) {
                let similarity = score(target.coarse, in: coarse, x: x, y: y)
                if similarity < 0.35 { continue }
                let candidate = Candidate(x: x, y: y, score: similarity)
                if let nearby = peaks.firstIndex(where: { abs($0.x - x) <= 2 && abs($0.y - y) <= 2 }) {
                    if peaks[nearby].score < similarity { peaks[nearby] = candidate }
                } else if peaks.count < 12 {
                    peaks.append(candidate)
                } else if let worst = peaks.indices.min(by: { peaks[$0].score < peaks[$1].score }), peaks[worst].score < similarity {
                    peaks[worst] = candidate
                }
            }
        }
        var best: Candidate?
        var alternatives: [Candidate] = []
        for peak in peaks {
            var local: Candidate?
            for y in (peak.y * 4 - 12)...(peak.y * 4 + 12) {
                for x in (peak.x * 4 - 8)...(peak.x * 4 + 8) {
                    guard abs(x - oldX) <= radius, abs(y - oldY) <= radius,
                          x >= 0, y >= 0, CGFloat(x) + target.rect.width <= CGFloat(frame.width),
                          CGFloat(y) + target.rect.height <= CGFloat(frame.height) else { continue }
                    let similarity = score(target.fine, in: frame, x: x, y: y)
                    if similarity > (local?.score ?? -1) { local = Candidate(x: x, y: y, score: similarity) }
                }
            }
            if let local {
                alternatives.append(local)
                if local.score > (best?.score ?? -1) { best = local }
            }
        }
        guard let best, best.score >= minimumConfidence else { return nil }
        let separation = max(5, Int(target.rect.height / 2))
        if alternatives.contains(where: {
            abs($0.x - best.x) + abs($0.y - best.y) >= separation && best.score - $0.score < ambiguityMargin
        }) { return nil }
        return best
    }

    private func descriptor(_ frame: GrayFrame, patch: CGRect, anchorX: Int, anchorY: Int, samples: Int) -> Descriptor? {
        let minX = max(0, Int(floor(patch.minX))), minY = max(0, Int(floor(patch.minY)))
        let maxX = min(frame.width, Int(ceil(patch.maxX))), maxY = min(frame.height, Int(ceil(patch.maxY)))
        guard maxX > minX, maxY > minY else { return nil }
        let width = maxX - minX, height = maxY - minY
        let cols = max(1, min(width, Int(sqrt(Double(samples * width) / Double(height)))))
        let rows = max(1, min(height, samples / cols))
        var points: [Point] = []
        for row in 0..<rows {
            let y0 = minY + row * height / rows, y1 = minY + (row + 1) * height / rows
            for col in 0..<cols {
                let x0 = minX + col * width / cols, x1 = minX + (col + 1) * width / cols
                var selectedX = (x0 + x1) / 2, selectedY = (y0 + y1) / 2, contrast = -1
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let value = Int(frame.bytes[y * frame.width + x])
                        let dx = abs(value - Int(frame.bytes[y * frame.width + min(x + 1, frame.width - 1)]))
                        let dy = abs(value - Int(frame.bytes[min(y + 1, frame.height - 1) * frame.width + x]))
                        if dx + dy > contrast { contrast = dx + dy; selectedX = x; selectedY = y }
                    }
                }
                points.append(Point(x: selectedX - anchorX, y: selectedY - anchorY,
                                    value: Double(frame.bytes[selectedY * frame.width + selectedX])))
            }
        }
        let sum = points.reduce(0.0) { $0 + $1.value }
        let variance = points.reduce(0.0) { $0 + $1.value * $1.value } - sum * sum / Double(points.count)
        guard points.count >= 8, variance / Double(points.count) >= 25 else { return nil }
        return Descriptor(points: points, sum: sum, variance: variance,
                          minX: points.map(\.x).min()!, maxX: points.map(\.x).max()!,
                          minY: points.map(\.y).min()!, maxY: points.map(\.y).max()!)
    }

    private func score(_ descriptor: Descriptor, in frame: GrayFrame, x: Int, y: Int) -> Double {
        guard x + descriptor.minX >= 0, y + descriptor.minY >= 0,
              x + descriptor.maxX < frame.width, y + descriptor.maxY < frame.height else { return -1 }
        var sum = 0.0, sumSquared = 0.0, product = 0.0
        for point in descriptor.points {
            let value = Double(frame.bytes[(y + point.y) * frame.width + x + point.x])
            sum += value
            sumSquared += value * value
            product += value * point.value
        }
        let count = Double(descriptor.points.count)
        let variance = sumSquared - sum * sum / count
        guard variance / count >= 25 else { return -1 }
        return (product - sum * descriptor.sum / count) / sqrt(variance * descriptor.variance)
    }
}
