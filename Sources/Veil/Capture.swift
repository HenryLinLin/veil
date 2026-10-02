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
    var onTrackedMasks: ((CGDirectDisplayID, [Mask], TimeInterval, [WindowSignature]) -> Void)?
    var onFailure: ((String, CGDirectDisplayID?) -> Void)?

    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "veil.capture", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "veil.ocr", qos: .userInitiated)
    private let trackingQueue = DispatchQueue(label: "veil.tracking", qos: .userInteractive)
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
    private var pendingTracking: [CGDirectDisplayID: RetainedFrame] = [:]
    private var latestTrackingInput: [CGDirectDisplayID: RetainedFrame] = [:]
    private var trackingInFlight: Set<CGDirectDisplayID> = []
    private var trackingStates: [CGDirectDisplayID: TrackingState] = [:]
    private var trackedDeliveries: [CGDirectDisplayID: TrackedDelivery] = [:]
    private var trackingDeliveryScheduled = false
    private var deliveredTrackingTime: [CGDirectDisplayID: TimeInterval] = [:]
    private var activeRequest: VNRecognizeTextRequest?

    private struct CaptureSource {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let bounds: CGRect
    }

    private struct GraySnapshot {
        let frame: GrayFrame
        let bounds: CGRect
        let timestamp: TimeInterval
        let windows: [WindowSignature]
    }

    private final class TrackingState {
        let generation: Int
        let revision: Int
        let tracker = TextMaskTracker()
        var latest: GraySnapshot?
        var masks: [Int: Mask] = [:]
        var fixedMasks: [Mask] = []
        var seedWindows: [WindowSignature] = []
        var seededAt: TimeInterval = -.infinity
        init(generation: Int, revision: Int) {
            self.generation = generation
            self.revision = revision
        }
    }

    private struct TrackedDelivery {
        let masks: [Mask]
        let timestamp: TimeInterval
        let windows: [WindowSignature]
    }

    init(engine: CoreEngine? = nil, maximumDimension: Int = 2560, fps: Int = 30) {
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
            pendingTracking.removeAll()
            latestTrackingInput.removeAll()
            trackingInFlight.removeAll()
            trackedDeliveries.removeAll()
            trackingDeliveryScheduled = false
            deliveredTrackingTime.removeAll()
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
                self.report("Scanning paused. Restart presenting to retry.", token: token, revision: revision, displayID: displayID)
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
            pendingTracking.removeAll()
            latestTrackingInput.removeAll()
            trackingInFlight.removeAll()
            trackedDeliveries.removeAll()
            trackingDeliveryScheduled = false
            deliveredTrackingTime.removeAll()
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
            self?.context.clearCaches()
        }
        trackingQueue.async { [weak self] in
            self?.trackingStates.removeAll()
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
        enqueueTracking(retained, token: token)
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
                do {
                    let result = try self.scan(image, displayID: displayID, displayBounds: displayBounds,
                                              dirty: retained.dirty, windows: retained.windows,
                                              token: token, settings: settings)
                    guard self.isActive(token, revision: settings.2) else { return }
                    let signatures = retained.windows.map {
                        WindowSignature(id: $0.id, pid: $0.pid, bounds: $0.bounds, layer: $0.layer, title: $0.title.hashValue)
                    }
                    let frame = CapturedFrame(image: image, displayID: displayID, displayBounds: displayBounds,
                                              scannedBounds: result.scannedBounds, timestamp: retained.timestamp,
                                              windows: signatures)
                    if settings.0, !settings.1, let gray = Self.grayFrame(retained.content) {
                        self.seedTracking(result.masks, source: GraySnapshot(frame: gray, bounds: displayBounds,
                                                                             timestamp: retained.timestamp, windows: signatures),
                                          displayID: displayID, token: token, revision: settings.2)
                    }
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
                        self.report("Scanning paused. Restart presenting to retry.", token: token, revision: settings.2, displayID: displayID)
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
        let crop = fullRect
        var masks: [Mask] = []
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

    private func enqueueTracking(_ retained: RetainedFrame, token: Int) {
        let ready = locked { () -> Bool in
            guard running, generation == token, revision == retained.revision, ocrEnabled, !fullFrameScanning else { return false }
            if retained.timestamp >= (latestTrackingInput[retained.displayID]?.timestamp ?? -.infinity) {
                latestTrackingInput[retained.displayID] = retained
            }
            if trackingInFlight.contains(retained.displayID) {
                if retained.timestamp >= (pendingTracking[retained.displayID]?.timestamp ?? -.infinity) {
                    pendingTracking[retained.displayID] = retained
                }
                return false
            }
            trackingInFlight.insert(retained.displayID)
            return true
        }
        if ready { processTracking(retained, token: token) }
    }

    private func processTracking(_ retained: RetainedFrame, token: Int) {
        trackingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.finishTracking(retained.displayID, token: token, revision: retained.revision) }
            guard self.isActive(token, revision: retained.revision) else { return }
            autoreleasepool {
                let state = self.trackingState(retained.displayID, token: token, revision: retained.revision)
                guard let snapshot = self.graySnapshot(retained) else {
                    state.tracker.reset()
                    state.masks.removeAll()
                    state.fixedMasks.removeAll()
                    let windows = retained.windows.map {
                        WindowSignature(id: $0.id, pid: $0.pid, bounds: $0.bounds, layer: $0.layer, title: $0.title.hashValue)
                    }
                    self.publishTracked([], displayID: retained.displayID, timestamp: retained.timestamp,
                                        windows: windows, token: token, revision: retained.revision)
                    self.clearTrackingInput(retained.displayID, through: retained.timestamp, token: token, revision: retained.revision)
                    return
                }
                self.clearTrackingInput(retained.displayID, through: snapshot.timestamp, token: token, revision: retained.revision)
                guard snapshot.timestamp >= (state.latest?.timestamp ?? -.infinity) else { return }
                state.latest = snapshot
                self.deliverTracking(state, displayID: retained.displayID, token: token, revision: retained.revision)
            }
        }
    }

    private func clearTrackingInput(_ displayID: CGDirectDisplayID, through timestamp: TimeInterval, token: Int, revision: Int) {
        locked {
            guard running, generation == token, self.revision == revision else { return }
            if let latest = latestTrackingInput[displayID], latest.timestamp <= timestamp {
                latestTrackingInput.removeValue(forKey: displayID)
            }
        }
    }

    private func finishTracking(_ displayID: CGDirectDisplayID, token: Int, revision: Int) {
        let next = locked { () -> RetainedFrame? in
            guard running, generation == token, self.revision == revision else { return nil }
            if let newest = pendingTracking.removeValue(forKey: displayID) { return newest }
            trackingInFlight.remove(displayID)
            return nil
        }
        if let next { processTracking(next, token: token) }
    }

    private func trackingState(_ displayID: CGDirectDisplayID, token: Int, revision: Int) -> TrackingState {
        if let state = trackingStates[displayID], state.generation == token, state.revision == revision { return state }
        let state = TrackingState(generation: token, revision: revision)
        trackingStates[displayID] = state
        return state
    }

    private func graySnapshot(_ retained: RetainedFrame) -> GraySnapshot? {
        guard let gray = Self.grayFrame(retained.content) else { return nil }
        let windows = retained.windows.map {
            WindowSignature(id: $0.id, pid: $0.pid, bounds: $0.bounds, layer: $0.layer, title: $0.title.hashValue)
        }
        return GraySnapshot(frame: gray, bounds: retained.displayBounds, timestamp: retained.timestamp, windows: windows)
    }

    private static func grayFrame(_ content: FrameContent) -> GrayFrame? {
        switch content {
        case .image(let image): return grayscale(image)
        case .buffer(let buffer): return grayscale(buffer)
        }
    }

    static func grayscale(_ buffer: CVPixelBuffer, maximumDimension: Int = 1280) -> GrayFrame? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let limit = max(1, min(1280, maximumDimension))
        let scale = min(1, Double(limit) / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int(Double(sourceWidth) * scale)), height = max(1, Int(Double(sourceHeight) * scale))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let source = base.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = min(sourceHeight - 1, (2 * y + 1) * sourceHeight / (2 * height)) * stride
            for x in 0..<width {
                let pixel = row + min(sourceWidth - 1, (2 * x + 1) * sourceWidth / (2 * width)) * 4
                bytes[y * width + x] = UInt8((54 * Int(source[pixel + 2]) + 183 * Int(source[pixel + 1]) + 19 * Int(source[pixel])) >> 8)
            }
        }
        return GrayFrame(width: width, height: height, bytes: bytes)
    }

    static func grayscale(_ image: CGImage, maximumDimension: Int = 1280) -> GrayFrame? {
        let limit = max(1, min(1280, maximumDimension))
        let scale = min(1, Double(limit) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? GrayFrame(width: width, height: height, bytes: bytes) : nil
    }

    private func seedTracking(_ masks: [Mask], source: GraySnapshot, displayID: CGDirectDisplayID, token: Int, revision: Int) {
        trackingQueue.async { [weak self] in
            guard let self, self.isActive(token, revision: revision) else { return }
            autoreleasepool {
                let state = self.trackingState(displayID, token: token, revision: revision)
                guard source.timestamp >= state.seededAt else { return }
                let pending = self.locked { self.latestTrackingInput[displayID] }
                if let pending, pending.revision == revision,
                   pending.timestamp > (state.latest?.timestamp ?? -.infinity), let latest = self.graySnapshot(pending) {
                    state.latest = latest
                    self.clearTrackingInput(displayID, through: latest.timestamp, token: token, revision: revision)
                }
                if source.timestamp > (state.latest?.timestamp ?? -.infinity) { state.latest = source }
                state.seededAt = source.timestamp
                state.seedWindows = source.windows
                state.fixedMasks = masks.filter { $0.rule == "private-key" }
                state.masks.removeAll(keepingCapacity: true)
                var boxes: [TextTrackBox] = []
                for (id, mask) in masks.filter({ $0.rule != "private-key" }).prefix(32).enumerated() {
                    let rect = mask.rect.intersection(source.bounds)
                    guard !rect.isEmpty, !rect.isNull else { continue }
                    let pixels = CGRect(x: (rect.minX - source.bounds.minX) / source.bounds.width * CGFloat(source.frame.width),
                                        y: (rect.minY - source.bounds.minY) / source.bounds.height * CGFloat(source.frame.height),
                                        width: rect.width / source.bounds.width * CGFloat(source.frame.width),
                                        height: rect.height / source.bounds.height * CGFloat(source.frame.height))
                    state.masks[id] = mask
                    boxes.append(TextTrackBox(id: id, rect: pixels))
                }
                state.tracker.seed(boxes: boxes, in: source.frame, at: source.timestamp)
                self.deliverTracking(state, displayID: displayID, token: token, revision: revision)
            }
        }
    }

    private func deliverTracking(_ state: TrackingState, displayID: CGDirectDisplayID, token: Int, revision: Int) {
        guard let latest = state.latest else { return }
        let tracked = state.tracker.track(in: latest.frame, at: latest.timestamp)
        var masks = tracked.compactMap { tracked -> Mask? in
            guard var mask = state.masks[tracked.id] else { return nil }
            mask.rect = CGRect(x: latest.bounds.minX + tracked.rect.minX / CGFloat(latest.frame.width) * latest.bounds.width,
                               y: latest.bounds.minY + tracked.rect.minY / CGFloat(latest.frame.height) * latest.bounds.height,
                               width: tracked.rect.width / CGFloat(latest.frame.width) * latest.bounds.width,
                               height: tracked.rect.height / CGFloat(latest.frame.height) * latest.bounds.height).intersection(latest.bounds)
            if mask.windowID != 0 {
                guard let owner = latest.windows.first(where: { $0.id == mask.windowID }),
                      let original = state.seedWindows.first(where: { $0.id == mask.windowID }),
                      owner.pid == original.pid, owner.title == original.title else { return nil }
                mask.rect = mask.rect.intersection(owner.bounds)
                mask.anchor = owner.bounds
            }
            return mask.rect.isEmpty || mask.rect.isNull ? nil : mask
        }
        masks += state.fixedMasks.compactMap { original -> Mask? in
            var mask = original
            if mask.windowID != 0 {
                guard let owner = latest.windows.first(where: { $0.id == mask.windowID }),
                      let previous = state.seedWindows.first(where: { $0.id == mask.windowID }),
                      owner.pid == previous.pid, owner.title == previous.title else { return nil }
                mask.rect = owner.bounds.intersection(latest.bounds)
                mask.anchor = owner.bounds
            }
            return mask.rect.isEmpty || mask.rect.isNull ? nil : mask
        }
        publishTracked(masks, displayID: displayID, timestamp: latest.timestamp, windows: latest.windows, token: token, revision: revision)
    }

    private func publishTracked(_ masks: [Mask], displayID: CGDirectDisplayID, timestamp: TimeInterval,
                                windows: [WindowSignature], token: Int, revision: Int) {
        let schedule = locked { () -> Bool in
            guard running, generation == token, self.revision == revision, !fullFrameScanning,
                  timestamp >= (deliveredTrackingTime[displayID] ?? -.infinity),
                  timestamp >= (trackedDeliveries[displayID]?.timestamp ?? -.infinity) else { return false }
            trackedDeliveries[displayID] = TrackedDelivery(masks: masks, timestamp: timestamp, windows: windows)
            if trackingDeliveryScheduled { return false }
            trackingDeliveryScheduled = true
            return true
        }
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.flushTracking(token: token, revision: revision) }
        }
    }

    private func flushTracking(token: Int, revision: Int) {
        let deliveries = locked { () -> [CGDirectDisplayID: TrackedDelivery] in
            guard running, generation == token, self.revision == revision else { return [:] }
            trackingDeliveryScheduled = false
            let result = trackedDeliveries
            trackedDeliveries.removeAll(keepingCapacity: true)
            for (displayID, value) in result { deliveredTrackingTime[displayID] = value.timestamp }
            return result
        }
        for (displayID, value) in deliveries {
            guard isActive(token, revision: revision) else { return }
            onTrackedMasks?(displayID, value.masks, value.timestamp, value.windows)
        }
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
