import AppKit
import CoreImage
@preconcurrency import CoreVideo
import ScreenCaptureKit
import Vision

struct CapturedFrame {
    let image: CGImage
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let scannedBounds: CGRect
    let timestamp: TimeInterval
    let windows: [WindowSignature]
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

private enum FrameContent: @unchecked Sendable {
    case buffer(CVPixelBuffer)
    case image(CGImage)
}

private struct RetainedFrame: @unchecked Sendable {
    let content: FrameContent
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let timestamp: TimeInterval
    let windows: [ScreenWindow]
    let dirty: [CGRect]?
    let revision: Int
}

final class ScreenCapture {
    var onScannedFrame: ((CapturedFrame, [Mask]) -> Void)?
    var onFailure: ((String, CGDirectDisplayID?) -> Void)?

    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "veil.capture", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "veil.ocr", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let engine: CoreEngine?
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
    private var pending: [CGDirectDisplayID: RetainedFrame] = [:]
    private var latestFrameTime: [CGDirectDisplayID: TimeInterval] = [:]
    private var captureSources: [CGDirectDisplayID: CaptureSource] = [:]
    private var screenshotInFlight: Set<CGDirectDisplayID> = []
    private var screenshotRetry: Set<CGDirectDisplayID> = []
    private var paths: [CGWindowID: (title: Int, path: String)] = [:]
    private var cache: [CGDirectDisplayID: ScanCache] = [:]
    private var activeRequest: VNRecognizeTextRequest?

    private struct CaptureSource {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let bounds: CGRect
    }

    private struct ScanCache {
        let generation: Int
        let revision: Int
        let imageSize: CGSize
    }

    init(engine: CoreEngine? = nil, maximumDimension: Int = 2560, fps: Int = 8) {
        self.engine = engine
        self.maximumDimension = max(640, maximumDimension)
        self.fps = max(1, min(30, fps))
    }

    func start(ocrEnabled: Bool = true, fullFrameScanning: Bool = false) async throws {
        guard !Task.isCancelled else { return }
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
            guard !ownApps.isEmpty else { throw CaptureError.ownApplicationMissing }
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
                config.showsCursor = fullFrameScanning
                config.capturesAudio = false
                config.queueDepth = 3
                config.colorSpaceName = CGColorSpace.sRGB
                let output = CaptureOutput(owner: self, display: display, generation: token)
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
                let added = locked { () -> Bool in
                    guard running, generation == token else { return false }
                    streams.append((stream, output))
                    captureSources[display.displayID] = CaptureSource(filter: filter, configuration: config,
                                                                     bounds: display.frame)
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
            pending.removeAll()
            screenshotRetry.formUnion(screenshotInFlight)
            needsFullScan.formUnion(streams.map { $0.1.displayID })
            return activeRequest
        }
        request?.cancel()
    }

    func updatePaths(_ paths: [CGWindowID: (title: Int, path: String)]) {
        locked { self.paths = paths }
    }

    func requestFullScan() {
        locked {
            needsFullScan.formUnion(streams.map { $0.1.displayID })
            needsFullScan.formUnion(inFlight)
        }
    }

    func rescanNow() {
        let requests = locked { () -> [(CGDirectDisplayID, CaptureSource, Int, Int)] in
            guard running else { return [] }
            var ready: [(CGDirectDisplayID, CaptureSource, Int, Int)] = []
            for (displayID, source) in captureSources {
                needsFullScan.insert(displayID)
                if screenshotInFlight.contains(displayID) {
                    screenshotRetry.insert(displayID)
                } else {
                    screenshotInFlight.insert(displayID)
                    ready.append((displayID, source, generation, revision))
                }
            }
            return ready
        }
        for (displayID, source, token, revision) in requests {
            screenshot(displayID, source: source, token: token, revision: revision)
        }
    }

    private func screenshot(_ displayID: CGDirectDisplayID, source: CaptureSource, token: Int, revision: Int) {
        guard isActive(token, revision: revision) else {
            finishScreenshot(displayID, token: token)
            return
        }
        let windows = ScreenWindow.visible()
        let timestamp = ProcessInfo.processInfo.systemUptime
        SCScreenshotManager.captureImage(contentFilter: source.filter, configuration: source.configuration) { [weak self] image, error in
            guard let self else { return }
            defer { self.finishScreenshot(displayID, token: token) }
            guard self.isActive(token, revision: revision) else { return }
            guard let image, error == nil else {
                self.report("Could not capture a fresh frame. Protection remains in place.", token: token, revision: revision, displayID: displayID)
                return
            }
            let retained = RetainedFrame(content: .image(image), displayID: displayID, displayBounds: source.bounds,
                                         timestamp: timestamp, windows: windows, dirty: nil, revision: revision)
            self.enqueue(retained, token: token, fullScan: true)
        }
    }

    private func finishScreenshot(_ displayID: CGDirectDisplayID, token: Int) {
        let retry = locked { () -> (CaptureSource, Int)? in
            guard running, generation == token else { return nil }
            if screenshotRetry.remove(displayID) != nil, let source = captureSources[displayID] {
                return (source, revision)
            }
            screenshotInFlight.remove(displayID)
            return nil
        }
        if let retry { screenshot(displayID, source: retry.0, token: token, revision: retry.1) }
    }

    func stop() {
        let stopped = locked { () -> ([(SCStream, CaptureOutput)], VNRecognizeTextRequest?) in
            generation += 1
            running = false
            inFlight.removeAll()
            needsFullScan.removeAll()
            pending.removeAll()
            latestFrameTime.removeAll()
            captureSources.removeAll()
            screenshotInFlight.removeAll()
            screenshotRetry.removeAll()
            paths.removeAll()
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
        guard isActive(token) else { return }
        let dirty = (metadata[.dirtyRects] as? [NSValue])?.map(\.rectValue)
        let now = ProcessInfo.processInfo.systemUptime
        let presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let timestamp = presentation.isFinite && presentation <= now && now - presentation < 2 ? presentation : now - 0.5
        let windows = ScreenWindow.visible()
        let currentRevision = locked { () -> Int? in
            guard running, generation == token else { return nil }
            return revision
        }
        guard let currentRevision else { return }
        let retained = RetainedFrame(content: .buffer(buffer), displayID: displayID, displayBounds: displayBounds,
                                     timestamp: timestamp, windows: windows, dirty: dirty, revision: currentRevision)
        enqueue(retained, token: token)
    }

    private func enqueue(_ retained: RetainedFrame, token: Int, fullScan: Bool = false) {
        let displayID = retained.displayID
        let work = locked { () -> (RetainedFrame, (Bool, Bool, Int, Bool))? in
            guard running, generation == token, retained.revision == revision else { return nil }
            if let latest = latestFrameTime[displayID], retained.timestamp < latest { return nil }
            latestFrameTime[displayID] = retained.timestamp
            if fullScan { needsFullScan.insert(displayID) }
            if inFlight.contains(displayID) {
                pending[displayID] = retained
                needsFullScan.insert(displayID)
                return nil
            }
            inFlight.insert(displayID)
            return (retained, (ocrEnabled, fullFrameScanning, revision, needsFullScan.remove(displayID) != nil))
        }
        if let work { process(work.0, token: token, settings: work.1) }
    }

    private func process(_ retained: RetainedFrame, token: Int, settings: (Bool, Bool, Int, Bool)) {
        scanQueue.async { [weak self] in
            guard let self else { return }
            let displayID = retained.displayID
            let displayBounds = retained.displayBounds
            var deliveryPending = false
            defer {
                if !deliveryPending { self.finish(displayID, token: token) }
            }
            guard self.isActive(token, revision: settings.2) else { return }
            autoreleasepool {
                let converted: CGImage?
                switch retained.content {
                case .image(let image): converted = image
                case .buffer(let buffer):
                    let input = CIImage(cvPixelBuffer: buffer)
                    converted = self.context.createCGImage(input, from: input.extent)
                }
                guard let image = converted else {
                    self.locked { if self.generation == token { self.needsFullScan.insert(displayID) } }
                    self.report("Could not read a captured frame.", token: token, revision: settings.2, displayID: displayID)
                    return
                }
                let size = CGSize(width: image.width, height: image.height)
                do {
                    let result = try self.scan(image, displayID: displayID, displayBounds: displayBounds,
                                              dirty: retained.dirty, windows: retained.windows,
                                              token: token, settings: settings)
                    guard self.isActive(token, revision: settings.2) else { return }
                    self.cache[displayID] = ScanCache(generation: token, revision: settings.2, imageSize: size)
                    let signatures = retained.windows.map {
                        WindowSignature(id: $0.id, pid: $0.pid, bounds: $0.bounds, layer: $0.layer, title: $0.title.hashValue)
                    }
                    let frame = CapturedFrame(image: image, displayID: displayID, displayBounds: displayBounds,
                                              scannedBounds: result.scannedBounds, timestamp: retained.timestamp,
                                              windows: signatures)
                    deliveryPending = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        defer { self.finish(displayID, token: token) }
                        guard self.isActive(token, revision: settings.2) else { return }
                        self.onScannedFrame?(frame, result.masks)
                    }
                } catch {
                    self.locked { if self.generation == token { self.needsFullScan.insert(displayID) } }
                    if self.isActive(token, revision: settings.2) {
                        self.report("Text scanning failed. Protection remains in place until scanning recovers.", token: token, revision: settings.2, displayID: displayID)
                    }
                }
            }
        }
    }

    private func scan(_ image: CGImage, displayID: CGDirectDisplayID, displayBounds: CGRect,
                      dirty: [CGRect]?, windows: [ScreenWindow], token: Int, settings: (Bool, Bool, Int, Bool)) throws
        -> (masks: [Mask], scannedBounds: CGRect) {
        guard settings.0 else { return ([], displayBounds) }
        guard let engine else { throw CaptureError.missingEngine }
        let imageSize = CGSize(width: image.width, height: image.height)
        let fullRect = CGRect(origin: .zero, size: imageSize)
        let previous = cache[displayID]
        let validCache = previous?.generation == token && previous?.revision == settings.2
            && previous?.imageSize == imageSize
        var crop = fullRect
        var masks: [Mask] = []
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
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.004
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
        let pathSnapshot = locked { paths }
        for observation in request.results ?? [] {
            guard isActive(token, revision: settings.2) else { throw CancellationError() }
            guard let text = observation.topCandidates(1).first, !text.string.isEmpty else { continue }
            let line = OCRLine(candidate: text, crop: crop, imageSize: imageSize,
                               displayBounds: displayBounds, observation: observation.boundingBox)
            let owner = windows.first {
                $0.bounds.contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY)) && $0.layer == 0
            }
            let path: String
            if let owner, let entry = pathSnapshot[owner.id], entry.title == owner.title.hashValue {
                path = entry.path
            } else { path = "" }
            for hit in try engine.scan(line.text, title: owner?.title ?? "", path: path, ocr: true) {
                let rect = hit.rule == "private-key" ? (owner?.bounds ?? displayBounds) :
                    (line.bounds(forUTF8Range: hit.start..<hit.end) ?? line.bounds).insetBy(dx: -4, dy: -4)
                masks.append(Mask(rect: rect.intersection(displayBounds), rule: hit.rule,
                                  app: owner?.app ?? "screen", hash: hit.hash,
                                  windowID: owner?.id ?? 0, anchor: owner?.bounds))
            }
        }
        let scanned = CGRect(x: displayBounds.minX,
                             y: displayBounds.minY + crop.minY / fullRect.height * displayBounds.height,
                             width: displayBounds.width,
                             height: crop.height / fullRect.height * displayBounds.height)
        return (masks, scanned)
    }

    fileprivate func report(_ message: String, token: Int, revision expectedRevision: Int? = nil, displayID: CGDirectDisplayID? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive(token, revision: expectedRevision) else { return }
            self.onFailure?(message, displayID)
        }
    }

    private func isActive(_ token: Int, revision expectedRevision: Int? = nil) -> Bool {
        locked { running && generation == token && (expectedRevision == nil || revision == expectedRevision) }
    }

    private func finish(_ displayID: CGDirectDisplayID, token: Int) {
        let work = locked { () -> (RetainedFrame, (Bool, Bool, Int, Bool))? in
            guard running, generation == token else { return nil }
            if let newest = pending.removeValue(forKey: displayID), newest.revision == revision {
                needsFullScan.remove(displayID)
                return (newest, (ocrEnabled, fullFrameScanning, revision, true))
            }
            inFlight.remove(displayID)
            return nil
        }
        if let work { process(work.0, token: token, settings: work.1) }
    }

    @discardableResult
    private func locked<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }
}

private enum CaptureError: LocalizedError {
    case noDisplays, invalidCrop, ownApplicationMissing, missingEngine
    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No display is available for capture."
        case .ownApplicationMissing: return "Veil could not exclude its own windows. Open Permissions & Test and retry."
        case .invalidCrop: return "The captured frame has invalid bounds."
        case .missingEngine: return "OCR detection is unavailable. Restart the protection session."
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
        owner?.report("Screen capture stopped: \(error.localizedDescription)", token: generation, displayID: displayID)
    }
}
