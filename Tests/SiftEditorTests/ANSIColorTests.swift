import AppKit
import XCTest
@testable import SiftEditorCore

final class ANSIColorTests: XCTestCase {
    private let palette = ANSIPalette.from(theme: EditorTheme.builtin(.system))
    private let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]

    /// 不含转义字符的行是 nil（调用者走常规路线）。
    func testNoEscapeReturnsNil() {
        XCTAssertNil(ANSIColor.attributed("plain log line", base: base, palette: palette))
    }

    /// 转义字符已被移除，只留下可见文本。
    func testStripsEscapes() {
        let line = "\u{1B}[31mERROR\u{1B}[0m done"
        let r = ANSIColor.attributed(line, base: base, palette: palette)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.plain, "ERROR done")
        XCTAssertEqual(r?.attributed.string, "ERROR done")
    }

    /// 前景色通过 SGR 切换，并通过 reset 恢复为默认值。
    func testForegroundColorRuns() {
        let line = "\u{1B}[31mRED\u{1B}[0mX"
        guard let r = ANSIColor.attributed(line, base: base, palette: palette) else { return XCTFail() }
        let attr = r.attributed
        // “RED”为红色（palette[1]），“X”没有颜色属性（默认前景色）。
        let redColor = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(redColor, ANSIPalette.xterm16[1])
        let xColor = attr.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertNil(xColor)
    }

    /// 背景色（40–47）和高亮度前景（90–97）。
    func testBackgroundAndBright() {
        let line = "\u{1B}[42;91mhi\u{1B}[0m"
        guard let r = ANSIColor.attributed(line, base: base, palette: palette) else { return XCTFail() }
        let fg = r.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let bg = r.attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(fg, ANSIPalette.xterm16[9])   // 91 = bright red
        XCTAssertEqual(bg, ANSIPalette.xterm16[2])   // 42 = green bg
    }

    /// 256 色 (38;5;n) 和 truecolor (38;2;r;g;b)。
    func testExtendedColors() {
        let c256 = ANSIColor.attributed("\u{1B}[38;5;196mX\u{1B}[0m", base: base, palette: palette)
        XCTAssertNotNil(c256?.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        let truecolor = ANSIColor.attributed("\u{1B}[38;2;10;20;30mX", base: base, palette: palette)
        let c = truecolor?.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let s = c?.usingColorSpace(.sRGB)
        XCTAssertEqual(s?.redComponent ?? -1, 10.0 / 255, accuracy: 0.001)
        XCTAssertEqual(s?.blueComponent ?? -1, 30.0 / 255, accuracy: 0.001)
    }

    /// 粗体和下划线文本将反映在属性中。
    func testBoldUnderline() {
        let line = "\u{1B}[1;4mX\u{1B}[0m"
        guard let r = ANSIColor.attributed(line, base: base, palette: palette) else { return XCTFail() }
        XCTAssertNotNil(r.attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let font = r.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        XCTAssertTrue(bold)
    }

    /// 除了  / SGR 之外，其他 CSI 条目（例如光标移动）也将从显示中移除。
    func testNonSGRCSIStripped() {
        let line = "a\u{1B}[2Kb\u{1B}[10;5Hc"
        let r = ANSIColor.attributed(line, base: base, palette: palette)
        XCTAssertEqual(r?.plain, "abc")
    }
}
