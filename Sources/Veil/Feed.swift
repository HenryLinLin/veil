import AppKit
import CoreImage
import Metal

final class FeedCompositor {
    private let context: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(context: CIContext? = MTLCreateSystemDefaultDevice().map {
        CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
    }) {
        self.context = context
    }

    var isAvailable: Bool { context != nil }

    func redact(_ image: CGImage, masks: [CGRect]) -> CGImage? {
        guard let context, image.width > 0, image.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let black = CIImage(color: CIColor(red: 0.025, green: 0.025, blue: 0.03, alpha: 1))
        var protected = CIImage(cgImage: image).composited(over: black.cropped(to: bounds))
        for mask in masks {
            guard [mask.minX, mask.minY, mask.maxX, mask.maxY, mask.width, mask.height].allSatisfy({ $0.isFinite }),
                  mask.width >= 0, mask.height >= 0 else { return nil }
            let padded = mask.integral.insetBy(dx: -3, dy: -3).intersection(bounds)
            if padded.isNull || padded.isEmpty { continue }
            let flipped = CGRect(x: padded.minX, y: bounds.height - padded.maxY,
                                 width: padded.width, height: padded.height)
            protected = black.cropped(to: flipped).composited(over: protected)
        }
        // TODO: preserve HDR color when the feed supports it.
        let scale = min(1, 1600 / bounds.width, 1000 / bounds.height)
        let outputBounds = CGRect(x: 0, y: 0, width: floor(bounds.width * scale),
                                  height: floor(bounds.height * scale))
        let output = protected.cropped(to: bounds).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(output, from: outputBounds, format: .RGBA8, colorSpace: colorSpace)
    }
}

struct DelayedFeedBuffer {
    private struct Frame {
        let image: CGImage
        let readyAt: TimeInterval
    }
    private var frames: [Frame] = []
    private var lastAccepted: TimeInterval?
    private(set) var currentDelay: TimeInterval = 0
    var count: Int { frames.count }

    func canAccept(at now: TimeInterval) -> Bool {
        frames.count < 6 && (lastAccepted.map { now - $0 >= max(0.1, currentDelay / 5) } ?? true)
    }

    mutating func setDelay(_ delay: TimeInterval) -> Bool {
        let boundedDelay = delay.isFinite ? min(max(delay, 0), 2) : 2
        if boundedDelay != currentDelay {
            clear()
            currentDelay = boundedDelay
            return true
        }
        return false
    }

    @discardableResult
    mutating func enqueue(_ image: CGImage, at now: TimeInterval, delay: TimeInterval) -> Bool {
        _ = setDelay(delay)
        guard canAccept(at: now) else { return false }
        lastAccepted = now
        frames.append(Frame(image: image, readyAt: now + currentDelay))
        return true
    }

    mutating func ready(at now: TimeInterval) -> CGImage? {
        var latest: CGImage?
        while let first = frames.first, first.readyAt <= now {
            latest = first.image
            frames.removeFirst()
        }
        return latest
    }

    mutating func clear() {
        frames.removeAll(keepingCapacity: false)
        lastAccepted = nil
    }
}

private final class FeedCanvas: NSView {
    var frameImage: CGImage? {
        didSet { needsDisplay = true }
    }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let frameImage else {
            let text = "Waiting for a protected frame"
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.lightGray,
                .paragraphStyle: style
            ]
            text.draw(in: NSRect(x: 12, y: bounds.midY - 12, width: max(0, bounds.width - 24), height: 30),
                      withAttributes: attributes)
            return
        }
        let scale = min(bounds.width / CGFloat(frameImage.width), bounds.height / CGFloat(frameImage.height))
        let size = NSSize(width: CGFloat(frameImage.width) * scale, height: CGFloat(frameImage.height) * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: frameImage, size: size).draw(in: rect)
    }
}

private final class FeedWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let canvas = FeedCanvas()
    var buffer = DelayedFeedBuffer()
    var lastFrameAt: TimeInterval?
    var onClose: (() -> Void)?

    init(displayID: UInt32) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(760, frame.width * 0.65)
        let size = NSSize(width: width, height: width * 9 / 16 + 32)
        let position = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        window = NSWindow(contentRect: NSRect(origin: position, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false, screen: screen)
        super.init()
        window.title = "Veil Feed – display \(displayID)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 210)
        window.delegate = self
        window.backgroundColor = .black
        let content = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        let caption = NSTextField(labelWithString: "Share this window · protected feed")
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        content.addSubview(canvas)
        content.addSubview(caption)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            caption.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -8)
        ])
        window.contentView = content
        window.orderFront(nil)
    }

    func tick(at now: TimeInterval) {
        if let lastFrameAt, now - lastFrameAt <= buffer.currentDelay + 2 {
            if let image = buffer.ready(at: now) { canvas.frameImage = image }
        } else {
            clear()
        }
    }

    func clear() {
        buffer.clear()
        canvas.frameImage = nil
        lastFrameAt = nil
    }

    func windowWillClose(_ notification: Notification) {
        clear()
        onClose?()
    }
}

final class FeedManager {
    private let compositor = FeedCompositor()
    private var windows: [UInt32: FeedWindow] = [:]
    private var dismissedDisplays = Set<UInt32>()
    private var timer: Timer?

    var isAvailable: Bool { compositor.isAvailable }
    func prepare(displayIDs: [UInt32]) {
        for id in Array(windows.keys) where !displayIDs.contains(id) { windows.removeValue(forKey: id)?.window.close() }
        dismissedDisplays.formIntersection(Set(displayIDs))
        for id in displayIDs where windows[id] == nil && !dismissedDisplays.contains(id) {
            let window = FeedWindow(displayID: id)
            windows[id] = window
            window.onClose = { [weak self] in
                self?.windows.removeValue(forKey: id)
                self?.dismissedDisplays.insert(id)
                self?.stopIfEmpty()
            }
        }
        if !windows.isEmpty { startTimer() }
    }

    func publish(displayID: UInt32, image: CGImage, masks: [CGRect], delay: Double) {
        precondition(Thread.isMainThread)
        guard !dismissedDisplays.contains(displayID) else { return }
        let feed: FeedWindow
        if let existing = windows[displayID] {
            feed = existing
        } else {
            feed = FeedWindow(displayID: displayID)
            windows[displayID] = feed
            feed.onClose = { [weak self] in
                self?.windows.removeValue(forKey: displayID)
                self?.dismissedDisplays.insert(displayID)
                self?.stopIfEmpty()
            }
            startTimer()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if feed.buffer.setDelay(delay) { feed.clear() }
        feed.tick(at: now)
        guard feed.buffer.canAccept(at: now) else { return }
        guard let protected = autoreleasepool(invoking: { compositor.redact(image, masks: masks) }) else {
            feed.clear()
            return
        }
        feed.lastFrameAt = now
        feed.buffer.enqueue(protected, at: now, delay: delay)
        feed.tick(at: ProcessInfo.processInfo.systemUptime)
    }

    func clear(displayID: UInt32? = nil) {
        precondition(Thread.isMainThread)
        if let displayID { windows[displayID]?.clear() }
        else { windows.values.forEach { $0.clear() } }
    }

    func closeAll() {
        precondition(Thread.isMainThread)
        let closing = Array(windows.values)
        windows.removeAll()
        closing.forEach { $0.window.close() }
        dismissedDisplays.removeAll()
        stopIfEmpty()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            windows.values.forEach { $0.tick(at: now) }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopIfEmpty() {
        if windows.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { timer?.invalidate() }
}
