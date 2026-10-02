import AppKit
import CoreImage
import CoreVideo

struct EngineMatch {
    let start: Int
    let end: Int
    let rule: String
    let hash: String
}
final class CoreEngine {
    func scan(_ text: String, title: String, path: String, ocr: Bool) throws -> [EngineMatch] { [] }
}

@main struct CaptureTests {
    static func main() {
        let pixels: [UInt8] = [0, 30, 60, 150, 200, 255]
        let image = CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 3,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let gray = ScreenCapture.grayscale(image)!
        precondition(gray.width == 3 && gray.height == 2)
        for (actual, expected) in zip(gray.bytes, pixels) { precondition(abs(Int(actual) - Int(expected)) <= 1) }
        let small = ScreenCapture.grayscale(image, maximumDimension: 2)!
        precondition(small.width == 2 && small.height == 1)

        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let captured = buffer!
        CVPixelBufferLockBaseAddress(captured, [])
        let data = CVPixelBufferGetBaseAddress(captured)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(captured)
        for y in 0..<2 {
            for x in 0..<3 {
                let offset = y * stride + x * 4
                let value: UInt8 = y == 0 ? 0 : 255
                data[offset] = value; data[offset + 1] = value; data[offset + 2] = value; data[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(captured, [])
        let capturedGray = ScreenCapture.grayscale(captured)!
        precondition(capturedGray.bytes.prefix(3).allSatisfy { $0 < 5 })
        precondition(capturedGray.bytes.suffix(3).allSatisfy { $0 > 250 })
        print("capture grayscale tests passed (CGImage and direct BGRA rows stay top-left)")
    }
}
