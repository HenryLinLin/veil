import AppKit
import ApplicationServices

struct EngineMatch {
    let start: Int
    let end: Int
    let rule: String
    let hash: String
}
final class CoreEngine {
    func scan(_ text: String, title: String, path: String) throws -> [EngineMatch] { [] }
}

@main struct AXBoundsTests {
    static func main() {
        let line = CGRect(x: 30, y: 40, width: 115, height: 20)
        let sample = "123-45-6789"
        let full = NSRange(location: 0, length: sample.utf16.count)
        precondition(AccessibilityReader.staticTextBounds(sample, match: full, role: kAXStaticTextRole, frame: line) == line)
        precondition(AccessibilityReader.staticTextBounds(sample, match: full, role: kAXTextAreaRole, frame: line) == nil)
        precondition(AccessibilityReader.staticTextBounds(sample, match: full, role: kAXStaticTextRole,
                                                         frame: CGRect(x: 0, y: 0, width: 900, height: 600)) == nil)
        precondition(AccessibilityReader.staticTextBounds(sample, match: full, role: kAXStaticTextRole,
                                                         frame: CGRect(x: 0, y: 0, width: 900, height: 20)) == nil)
        let paragraph = "Ordinary notes for this document. Sample: " + sample
        precondition(AccessibilityReader.staticTextBounds(paragraph, match: NSRange(location: paragraph.utf16.count - 11, length: 11),
                                                         role: kAXStaticTextRole, frame: line) == nil)
        precondition(AccessibilityReader.staticTextBounds(sample + "\n", match: full, role: kAXStaticTextRole, frame: line) == nil)
        precondition(AccessibilityReader.staticTextBounds(sample, match: NSRange(location: 0, length: 100), role: kAXStaticTextRole, frame: line) == nil)
        let spaced = "  " + sample + "  "
        precondition(AccessibilityReader.staticTextBounds(spaced, match: NSRange(location: 2, length: 11), role: kAXStaticTextRole, frame: line) == line)
        let unicode = "123–45–6789"
        precondition(AccessibilityReader.staticTextBounds(unicode, match: NSRange(location: 0, length: unicode.utf16.count),
                                                         role: kAXStaticTextRole, frame: line) == line)
        precondition(AccessibilityReader.rangeTextBounds(line, text: sample) == line)
        precondition(AccessibilityReader.rangeTextBounds(CGRect(x: 0, y: 0, width: 900, height: 600), text: sample) == nil)
        precondition(AccessibilityReader.rangeTextBounds(CGRect(x: 0, y: 0, width: 900, height: 20), text: sample) == nil)
        precondition(AccessibilityReader.rangeTextBounds(line, text: sample + "\n") == nil)
        print("AX bounds tests passed")
    }
}
