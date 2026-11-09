import XCTest
import AppKit
@testable import SiftEditorCore

/// 行显示验证（行索引 = 行号边栏/插入符位置、不可见字符符号、行分割）。
final class LineDisplayTests: XCTestCase {

    // MARK: - 行頭索引（LineStartIndex）

    func testEmptyTextHasOneLine() {
        let index = LineStartIndex("")
        XCTAssertEqual(index.lineCount, 1)
        XCTAssertEqual(index.lineIndex(at: 0), 0)
    }

    func testLineIndexAtOffsets() {
        //           0123 456789
        let text = "abc\ndef\n\nxy"
        let index = LineStartIndex(text)
        XCTAssertEqual(index.lineCount, 4)         // "abc" / "def" / "" / "xy"
        XCTAssertEqual(index.lineIndex(at: 0), 0)
        XCTAssertEqual(index.lineIndex(at: 3), 0)  // 行尾的换行符属于该行。
        XCTAssertEqual(index.lineIndex(at: 4), 1)  // 下一行的开始
        XCTAssertEqual(index.lineIndex(at: 8), 2)  // 空行
        XCTAssertEqual(index.lineIndex(at: 9), 3)
        XCTAssertEqual(index.start(ofLine: 3), 9)
    }

    func testTrailingNewlineGivesAnEmptyLastLine() {
        let index = LineStartIndex("a\nb\n")
        XCTAssertEqual(index.lineCount, 3)          // 你也可以将插入符号放在末尾的换行符之后。
        XCTAssertEqual(index.lineIndex(at: 4), 2)
    }

    func testPositionIsOneBasedAndCountsCharactersNotUTF16() {
        let text = "abc\nあ🚀z" as NSString
        let index = LineStartIndex(text)
        XCTAssertEqual(index.position(at: 0, in: text).line, 1)
        XCTAssertEqual(index.position(at: 0, in: text).column, 1)
        XCTAssertEqual(index.position(at: 2, in: text).column, 3)   // 中“ab”之后的第三位数字
        // 第 2 行：一个假名（UTF-16 长度 1）加 🚀（UTF-16 长度 2）之后是第 3 列；代理项对算一个字符。
        let afterRocket = 4 + 1 + 2
        XCTAssertEqual(index.position(at: afterRocket, in: text).line, 2)
        XCTAssertEqual(index.position(at: afterRocket, in: text).column, 3)
    }

    func testPositionClampsOutOfRange() {
        let text = "ab" as NSString
        let index = LineStartIndex(text)
        XCTAssertEqual(index.position(at: 99, in: text).column, 3)
        XCTAssertEqual(index.position(at: -5, in: text).column, 1)
    }

    // MARK: - 不可见字符符号

    func testTabAndIdeographicSpaceMarkers() {
        let markers = InvisibleGlyphs.markers(in: "a\tb　c")
        XCTAssertEqual(markers, [
            .init(utf16Index: 1, glyph: InvisibleGlyphs.tab),
            .init(utf16Index: 3, glyph: InvisibleGlyphs.ideographicSpace),
        ])
    }

    /// 行尾只会显示半角空格（在文本中用点表示空格会使文本无法阅读）。
    func testOnlyTrailingHalfWidthSpacesAreMarked() {
        let markers = InvisibleGlyphs.markers(in: "a b  ")
        XCTAssertEqual(markers.map(\.utf16Index), [3, 4])
        XCTAssertTrue(markers.allSatisfy { $0.glyph == InvisibleGlyphs.trailingSpace })
    }

    func testAllSpacesLineIsAllTrailing() {
        XCTAssertEqual(InvisibleGlyphs.markers(in: "   ").count, 3)
        XCTAssertTrue(InvisibleGlyphs.markers(in: "").isEmpty)
        XCTAssertTrue(InvisibleGlyphs.markers(in: "abc").isEmpty)
    }

    // MARK: - 分割线

    func testSplitByComma() {
        let out = LineSplitter.split("a,b,c", options: .init(delimiter: ","))
        XCTAssertEqual(out, "a\nb\nc")
    }

    func testSplitKeepsTrailingNewlineAndHandlesEachLine() {
        let out = LineSplitter.split("a,b\nc,d\n", options: .init(delimiter: ","))
        XCTAssertEqual(out, "a\nb\nc\nd\n")
    }

    func testSplitByEscapedTab() {
        let out = LineSplitter.split("a\tb", options: .init(delimiter: "\\t"))
        XCTAssertEqual(out, "a\nb")
    }

    func testSplitTrimAndDropEmpty() {
        let opts = LineSplitter.Options(delimiter: ",", trimEach: true, dropEmpty: true)
        XCTAssertEqual(LineSplitter.split("a , ,b ", options: opts), "a\nb")
        // 默认设置（不含 trim/drop）将空元素视为行。
        XCTAssertEqual(LineSplitter.split("a,,b", options: .init(delimiter: ",")), "a\n\nb")
    }

    func testSplitWithEmptyDelimiterIsRefused() {
        XCTAssertNil(LineSplitter.split("abc", options: .init(delimiter: "")))
    }

    /// 在日语键盘上，同一个键用于输入 `¥`，因此它被视为与反斜杠相同。
    func testUnescapeAcceptsYenSignAsEscapeLeader() {
        XCTAssertEqual(LineSplitter.unescape("¥t"), "\t")
        XCTAssertEqual(LineSplitter.unescape("￥n"), "\n")
        XCTAssertEqual(LineSplitter.unescape("¥¥"), "¥")
        XCTAssertEqual(LineSplitter.split("a\tb", options: .init(delimiter: "¥t")), "a\nb")
    }

    func testUnescapeLeavesUnknownEscapesAlone() {
        XCTAssertEqual(LineSplitter.unescape("\\t"), "\t")
        XCTAssertEqual(LineSplitter.unescape("\\n"), "\n")
        XCTAssertEqual(LineSplitter.unescape("\\\\"), "\\")
        XCTAssertEqual(LineSplitter.unescape("\\q"), "\\q")
        XCTAssertEqual(LineSplitter.unescape("a\\"), "a\\")
    }

    /// 这是连接的逆操作（连接 → 拆分返回到原始行数）。
    func testJoinThenSplitRoundTrip() {
        let source = "alpha\nbeta\ngamma"
        let joined = try! XCTUnwrap(TextTransform.joinLines.apply(source))
        XCTAssertEqual(joined, "alpha beta gamma")
        XCTAssertEqual(LineSplitter.split(joined, options: .init(delimiter: " ")), source)
    }

    // MARK: - 状态栏（小文件窗格）中的光标位置

    func testEditableViewerReportsCaretPosition() {
        let v = EditableViewer()
        var latest: ViewerState?
        v.onStateChange = { latest = $0 }
        v.newDocument()
        v._testSetText("abc\nあいう\n")
        v._testSelect(NSRange(location: 6, length: 0))   // ，第二行，“ai”之后
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 2)
        XCTAssertEqual(latest?.caret?.column, 3)

        v._testSelect(NSRange(location: 0, length: 0))
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 1)
        XCTAssertEqual(latest?.caret?.column, 1)
    }

    /// 即使在编辑过程中行发生偏移，它也会返回正确的行（通过丢弃索引缓存）。
    func testCaretPositionFollowsEdits() {
        let v = EditableViewer()
        var latest: ViewerState?
        v.onStateChange = { latest = $0 }
        v.newDocument()
        v._testSetText("one\ntwo")
        v._testSelect(NSRange(location: 7, length: 0))
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 2)

        v._testSetText("one\nmore\ntwo")
        v._testSelect(NSRange(location: 12, length: 0))
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 3)
        XCTAssertEqual(latest?.caret?.column, 4)
    }
}
