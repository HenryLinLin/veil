import Foundation
import CoreGraphics
import CoreText
import Darwin

func rendered(_ rows: [(String, CGFloat, CGFloat)], fontSize: CGFloat = 16) -> (GrayFrame, CGRect) {
    let width = 1280, height = 720
    var bytes = [UInt8](repeating: 255, count: width * height)
    bytes.withUnsafeMutableBytes { memory in
        let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        for (text, x, y) in rows {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Arial" as CFString, fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - y)
            CTLineDraw(line, context)
        }
    }
    var x0 = width, y0 = height, x1 = 0, y1 = 0
    for y in 0..<height { for x in 0..<width where bytes[y * width + x] < 230 {
        x0 = min(x0,x); y0 = min(y0,y); x1 = max(x1,x); y1 = max(y1,y)
    } }
    return (GrayFrame(width: width, height: height, bytes: bytes), CGRect(x: x0-2, y: y0-2, width: x1-x0+5, height: y1-y0+5))
}

@main struct RenderedTextTests {
    static func main() {
        setbuf(stdout,nil)
        for text in ["123-45-6789", "4111 1111 1111 1111", "This is an ordinary harmless paragraph"] {
            for size: CGFloat in [12, 16, 20] {
                let source = rendered([(text,300.25,300.25)],fontSize:size)
                let tracker = TextMaskTracker()
                tracker.seed(boxes: [TextTrackBox(id:1,rect:source.1)],in:source.0,at:0)
                for (index,shift): (Int,CGFloat) in [40.0,-40.0,1.0,-1.0].enumerated() {
                    let frame = rendered([(text,301.75,300.75+shift)],fontSize:size)
                    let result = tracker.track(in:frame.0,at:1+Double(index)/30)
                    guard result.count == 1, abs(result[0].rect.minX-frame.1.minX)<=2,
                          abs(result[0].rect.minY-frame.1.minY)<=2, result[0].rect.size == source.1.size else {
                        fatalError("rendered text translation failed")
                    }
                }
            }
        }
        for text in ["123-45-6789", "4111 1111 1111 1111", "This is an ordinary harmless paragraph"] {
            let source = rendered([(text,300,300)])
            let tracker = TextMaskTracker()
            tracker.seed(boxes: [TextTrackBox(id:1,rect:source.1)],in:source.0,at:0)
            let repeated = rendered([(text,300,260),(text,300,340)])
            guard tracker.track(in:repeated.0,at:1).isEmpty else { fatalError("ambiguous duplicate rows") }
            for shift: CGFloat in [-200,200] {
                tracker.seed(boxes: [TextTrackBox(id:1,rect:source.1)],in:source.0,at:0)
                let distant = rendered([(text,300,300+shift)])
                let result = tracker.track(in:distant.0,at:1)
                guard result.count == 1, abs(result[0].rect.minY-distant.1.minY)<=2 else {
                    fatalError("wide initial OCR alignment failed")
                }
            }
        }
        print("rendered text fixtures passed")
    }
}
