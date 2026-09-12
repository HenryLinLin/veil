import AppKit
import CoreImage
import ScreenCaptureKit
import Vision

struct CapturedFrame {
    let image: CGImage
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let scannedBounds: CGRect
    let timestamp: TimeInterval
}

struct OCRLine {
    let text: String
    let bounds: CGRect
    private let candidate: VNRecognizedText
    private let crop: CGRect
    private let imageSize: CGSize
    private let displayBounds: CGRect

    fileprivate init(candidate: VNRecognizedText, crop: CGRect, imageSize: CGSize,
                     displayBounds: CGRect, observation: CGRect) {
        self.candidate = candidate
        self.text = candidate.string
        self.crop = crop
        self.imageSize = imageSize
        self.displayBounds = displayBounds
        self.bounds = Self.convert(observation, crop: crop, imageSize: imageSize,
                                   displayBounds: displayBounds)
    }

    func bounds(forUTF8Range range: Range<Int>) -> CGRect? {
        guard range.lowerBound >= 0, range.upperBound <= text.utf8.count,
              let lo = text.utf8.index(text.utf8.startIndex, offsetBy: range.lowerBound,
                                       limitedBy: text.utf8.endIndex),
              let hi = text.utf8.index(text.utf8.startIndex, offsetBy: range.upperBound,
                                       limitedBy: text.utf8.endIndex),
              let start = String.Index(lo, within: text),
              let end = String.Index(hi, within: text), start < end,
              let box = try? candidate.boundingBox(for: start..<end) else { return nil }
        return Self.convert(box.boundingBox, crop: crop, imageSize: imageSize,
                            displayBounds: displayBounds)
    }

    private static func convert(_ box: CGRect, crop: CGRect, imageSize: CGSize,
                                displayBounds: CGRect) -> CGRect {
        let sx = displayBounds.width / imageSize.width
        let sy = displayBounds.height / imageSize.height
        return CGRect(x: displayBounds.minX + (crop.minX + box.minX * crop.width) * sx,
                      y: displayBounds.minY + (crop.minY + (1 - box.maxY) * crop.height) * sy,
                      width: box.width * crop.width * sx,
                      height: box.height * crop.height * sy)
    }
}

final class ScreenCapture {
    var onScannedFrame: ((CapturedFrame, [OCRLine]) -> Void)?
    var onFailure: ((String) -> Void)?

    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "veil.capture", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "veil.ocr", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let maximumDimension: Int
    private let fps: Int
    private var generation = 0
    private var revision = 0
    private var running = false
    private var ocrEnabled = true
    private var fullFrameScanning = false
    private var streams: [(SCStream, CaptureOutput)] = []
    private var inFlight: Set<CGDirectDisplayID> = []
    private var needsFullScan: Set<CGDirectDisplayID> = []
    private var cache: [CGDirectDisplayID: ScanCache] = [:]
    private var activeRequest: VNRecognizeTextRequest?

    private struct ScanCache {
        let generation: Int
        let revision: Int
        let imageSize: CGSize
    }

    init(maximumDimension: Int = 1600, fps: Int = 8) {
        self.maximumDimension = max(640, maximumDimension)
        self.fps = max(1, min(30, fps))
    }

    func start(ocrEnabled: Bool = true, fullFrameScanning: Bool = false) async throws {
        stop()
        let token = locked { () -> Int in
            self.ocrEnabled = ocrEnabled
            self.fullFrameScanning = fullFrameScanning
            running = true
            return generation
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard isActive(token) else { return }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let testWindows = content.windows.filter {
                $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.title == "Veil Test"
            }
            guard !content.displays.isEmpty else { throw CaptureError.noDisplays }
            for display in content.displays {
                guard isActive(token) else { return }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps,
                                             exceptingWindows: testWindows)
                let config = SCStreamConfiguration()
                let width = max(1, CGDisplayPixelsWide(display.displayID))
                let height = max(1, CGDisplayPixelsHigh(display.displayID))
                let scale = min(1, Double(maximumDimension) / Double(max(width, height)))
                config.width = max(1, Int(Double(width) * scale))
                config.height = max(1, Int(Double(height) * scale))
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.capturesAudio = false
                config.queueDepth = 3
                config.colorSpaceName = CGColorSpace.sRGB
                let output = CaptureOutput(owner: self, display: display, generation: token)
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
                let added = locked { () -> Bool in
                    guard running, generation == token else { return false }
                    streams.append((stream, output))
                    return true
                }
                guard added else { return }
                try await stream.startCapture()
                if !isActive(token) { try? await stream.stopCapture(); return }
            }
        } catch {
            if isActive(token) { stop(); throw error }
        }
    }

    func configure(ocrEnabled: Bool, fullFrameScanning: Bool) {
        let request = locked { () -> VNRecognizeTextRequest? in
            guard self.ocrEnabled != ocrEnabled || self.fullFrameScanning != fullFrameScanning else { return nil }
            self.ocrEnabled = ocrEnabled
            self.fullFrameScanning = fullFrameScanning
            revision += 1
            return activeRequest
        }
        request?.cancel()
    }

    func stop() {
        let stopped = locked { () -> ([(SCStream, CaptureOutput)], VNRecognizeTextRequest?) in
            generation += 1
            running = false
            inFlight.removeAll()
            needsFullScan.removeAll()
            let old = streams
            streams = []
            return (old, activeRequest)
        }
        stopped.1?.cancel()
        for (stream, output) in stopped.0 {
            Task {
                try? await stream.stopCapture()
                _ = output
            }
        }
        scanQueue.async { [weak self] in
            self?.cache.removeAll()
            self?.context.clearCaches()
        }
    }

    fileprivate func receive(_ sample: CMSampleBuffer, displayID: CGDirectDisplayID,
                             displayBounds: CGRect, token: Int) {
        guard sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let metadata = attachments.first,
              let rawStatus = metadata[.status] as? Int,
              rawStatus == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer else { return }
        let settings = locked { () -> (Bool, Bool, Int, Bool)? in
            guard running, generation == token else { return nil }
            guard !inFlight.contains(displayID) else {
                needsFullScan.insert(displayID)
                return nil
            }
            inFlight.insert(displayID)
            return (ocrEnabled, fullFrameScanning, revision, needsFullScan.remove(displayID) != nil)
        }
        guard let settings else { return }
        let dirty = (metadata[.dirtyRects] as? [NSValue])?.map(\.rectValue)
        let timestamp = ProcessInfo.processInfo.systemUptime
        scanQueue.async { [weak self] in
            guard let self else { return }
            var deliveryPending = false
            defer {
                if !deliveryPending { self.finish(displayID, token: token) }
            }
            guard self.isActive(token, revision: settings.2) else { return }
            autoreleasepool {
                let input = CIImage(cvPixelBuffer: buffer)
                guard let image = self.context.createCGImage(input, from: input.extent) else {
                    self.report("Could not read a captured frame.", token: token)
                    return
                }
                let size = CGSize(width: image.width, height: image.height)
                do {
                    let result = try self.scan(image, displayID: displayID, displayBounds: displayBounds,
                                              dirty: dirty, token: token, settings: settings)
                    self.cache[displayID] = ScanCache(generation: token, revision: settings.2,
                                                      imageSize: size)
                    let frame = CapturedFrame(image: image, displayID: displayID, displayBounds: displayBounds,
                                              scannedBounds: result.scannedBounds, timestamp: timestamp)
                    deliveryPending = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        defer { self.finish(displayID, token: token) }
                        guard self.isActive(token, revision: settings.2) else { return }
                        self.onScannedFrame?(frame, result.lines)
                    }
                } catch {
                    self.locked { self.needsFullScan.insert(displayID) }
                    if self.isActive(token, revision: settings.2) {
                        self.report("Text scanning failed. The clean feed is holding its last scanned frame.", token: token)
                    }
                }
            }
        }
    }

    private func scan(_ image: CGImage, displayID: CGDirectDisplayID, displayBounds: CGRect,
                      dirty: [CGRect]?, token: Int, settings: (Bool, Bool, Int, Bool)) throws
        -> (lines: [OCRLine], scannedBounds: CGRect) {
        guard settings.0 else { return ([], displayBounds) }
        let imageSize = CGSize(width: image.width, height: image.height)
        let fullRect = CGRect(origin: .zero, size: imageSize)
        let previous = cache[displayID]
        let validCache = previous?.generation == token && previous?.revision == settings.2
            && previous?.imageSize == imageSize
        var crop = fullRect
        var lines: [OCRLine] = []
        if !settings.1, !settings.3, validCache, let dirty {
            if dirty.isEmpty { return ([], .null) }
            let changed = dirty.reduce(CGRect.null) { $0.union($1) }.intersection(fullRect)
            if changed.isNull || changed.isEmpty { return ([], .null) }
            // Full-width bands keep tokens intact when one character changes.
            crop = CGRect(x: 0, y: max(0, changed.minY - 48), width: fullRect.width,
                          height: min(fullRect.maxY, changed.maxY + 48) - max(0, changed.minY - 48)).integral
        }
        guard let cropped = image.cropping(to: crop) else { throw CaptureError.invalidCrop }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.008
        let accepted = locked { () -> Bool in
            guard running, generation == token, revision == settings.2 else { return false }
            activeRequest = request
            return true
        }
        guard accepted else { throw CancellationError() }
        defer {
            locked {
                if activeRequest === request { activeRequest = nil }
            }
        }
        try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first, !text.string.isEmpty else { continue }
            lines.append(OCRLine(candidate: text, crop: crop, imageSize: imageSize,
                                 displayBounds: displayBounds, observation: observation.boundingBox))
        }
        let scanned = CGRect(x: displayBounds.minX,
                             y: displayBounds.minY + crop.minY / fullRect.height * displayBounds.height,
                             width: displayBounds.width,
                             height: crop.height / fullRect.height * displayBounds.height)
        return (lines, scanned)
    }

    fileprivate func report(_ message: String, token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive(token) else { return }
            self.onFailure?(message)
        }
    }

    private func isActive(_ token: Int, revision expectedRevision: Int? = nil) -> Bool {
        locked { running && generation == token && (expectedRevision == nil || revision == expectedRevision) }
    }

    private func finish(_ displayID: CGDirectDisplayID, token: Int) {
        locked {
            if generation == token { inFlight.remove(displayID) }
        }
    }

    @discardableResult
    private func locked<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }
}

private enum CaptureError: LocalizedError {
    case noDisplays, invalidCrop
    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No display is available for capture."
        case .invalidCrop: return "The captured frame has invalid bounds."
        }
    }
}

private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var owner: ScreenCapture?
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let generation: Int

    init(owner: ScreenCapture, display: SCDisplay, generation: Int) {
        self.owner = owner
        self.displayID = display.displayID
        self.displayBounds = display.frame
        self.generation = generation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        owner?.receive(sampleBuffer, displayID: displayID, displayBounds: displayBounds, token: generation)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.report("Screen capture stopped: \(error.localizedDescription)", token: generation)
    }
}
