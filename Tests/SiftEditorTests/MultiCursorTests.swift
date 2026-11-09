import XCTest
import AppKit
@testable import SiftEditorCore

/// 多光标（范围计算 + NSTextView 上的实际行为），序列号参数化，
/// 核实替代案例的维护情况。
final class MultiCursorTests: XCTestCase {

    // MARK: - 范围集 (MultiCursor)

    func testTogglingAddsThenRemovesSameCaret() {
        let one = [NSRange(location: 3, length: 0)]
        let two = MultiCursor.toggling(one, at: NSRange(location: 7, length: 0))
        XCTAssertEqual(two, [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)])
        // ⌘再次单击同一位置 = 取消选择光标。
        XCTAssertEqual(MultiCursor.toggling(two, at: NSRange(location: 7, length: 0)), one)
    }

    /// 无法移除最后一个部件（无法创建 0 个插入符的状态）。
    func testTogglingKeepsLastCaret() {
        let one = [NSRange(location: 3, length: 0)]
        XCTAssertEqual(MultiCursor.toggling(one, at: NSRange(location: 3, length: 0)), one)
    }

    func testNormalizeSortsAndMergesOverlaps() {
        let ranges = [NSRange(location: 10, length: 3), NSRange(location: 0, length: 2),
                      NSRange(location: 11, length: 5)]
        XCTAssertEqual(MultiCursor.normalize(ranges),
                       [NSRange(location: 0, length: 2), NSRange(location: 10, length: 6)])
    }

    /// 落入选区内/选区边缘的空光标会被吸收到选区中（不会创建重复光标）。
    func testNormalizeAbsorbsCaretsInsideSelection() {
        let ranges = [NSRange(location: 5, length: 3), NSRange(location: 6, length: 0),
                      NSRange(location: 8, length: 0)]
        XCTAssertEqual(MultiCursor.normalize(ranges), [NSRange(location: 5, length: 3)])
    }

    // MARK: - 在上方和下方添加插入符号

    func testAddCaretBelowKeepsColumn() {
        let text = "abcdef\nghijkl\n" as NSString
        let ranges = [NSRange(location: 3, length: 0)]           // 1 行目・3 桁目
        let out = MultiCursor.addingCaret(to: ranges, above: false, in: text)
        XCTAssertEqual(out, [NSRange(location: 3, length: 0), NSRange(location: 10, length: 0)])
    }

    /// 如果相邻行较短，则在该行末尾停止（不要跳过换行符并进入下一行）。
    func testAddCaretBelowClampsToShorterLine() {
        let text = "abcdef\ngh\n" as NSString
        let out = MultiCursor.addingCaret(to: [NSRange(location: 5, length: 0)], above: false, in: text)
        XCTAssertEqual(out.last, NSRange(location: 9, length: 0))   // "gh" 行尾
    }

    func testAddCaretAboveAtFirstLineDoesNothing() {
        let text = "abc\ndef" as NSString
        let ranges = [NSRange(location: 1, length: 0)]
        XCTAssertEqual(MultiCursor.addingCaret(to: ranges, above: true, in: text), ranges)
    }

    func testAddCaretBelowAtLastLineDoesNothing() {
        let text = "abc\ndef" as NSString
        let ranges = [NSRange(location: 5, length: 0)]
        XCTAssertEqual(MultiCursor.addingCaret(to: ranges, above: false, in: text), ranges)
    }

    // MARK: - 下一个相同的单词 (⌘D)

    func testWordRangeAtCaretInsideAndAfterWord() {
        let text = "let total = 1" as NSString
        XCTAssertEqual(MultiCursor.wordRange(at: 5, in: text), NSRange(location: 4, length: 5))
        // 当插入符号紧跟在单词后面时，表示该单词被选中。
        XCTAssertEqual(MultiCursor.wordRange(at: 9, in: text), NSRange(location: 4, length: 5))
        XCTAssertNil(MultiCursor.wordRange(at: 11, in: text))  // "=" 后面跟着一个空格 = 没有单词可以理解。
    }

    func testNextOccurrenceSkipsAlreadySelectedAndWraps() {
        let text = "foo bar foo baz foo" as NSString
        let selected = [NSRange(location: 0, length: 3)]
        let second = MultiCursor.nextOccurrence(of: "foo", in: text, after: 3, excluding: selected)
        XCTAssertEqual(second, NSRange(location: 8, length: 3))

        // 取完结尾后，移到开头，跳过任何已选择的匹配项，得到 nil。
        let all = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 16, length: 3)]
        XCTAssertNil(MultiCursor.nextOccurrence(of: "foo", in: text, after: 19, excluding: all))
    }

    // MARK: - 编辑后的光标位置

    func testCaretsAfterReplacingAccumulateOffsets() {
        let ranges = [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)]
        XCTAssertEqual(MultiCursor.caretsAfterReplacing(ranges, with: ["X", "X"]),
                       [NSRange(location: 1, length: 0), NSRange(location: 6, length: 0)])
    }

    func testCaretsAfterReplacingSelections() {
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 10, length: 3)]
        // 第一个字符减少一个字符，所以第二个插入符号是 10 + 2 - 1 = 11。
        XCTAssertEqual(MultiCursor.caretsAfterReplacing(ranges, with: ["ab", "ab"]),
                       [NSRange(location: 2, length: 0), NSRange(location: 11, length: 0)])
    }

    func testDeletionRangesBackwardDropsCaretAtDocumentStart() {
        let text = "abc\ndef" as NSString
        let ranges = [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)]
        XCTAssertEqual(MultiCursor.deletionRanges(ranges, forward: false, in: text),
                       [NSRange(location: 5, length: 1)])
    }

    func testDeletionRangesForwardKeepsSelections() {
        let text = "abcdef" as NSString
        let ranges = [NSRange(location: 1, length: 2), NSRange(location: 5, length: 0)]
        XCTAssertEqual(MultiCursor.deletionRanges(ranges, forward: true, in: text),
                       [NSRange(location: 1, length: 2), NSRange(location: 5, length: 1)])
    }

    // MARK: - NSTextView 实际行为 (EditorTextView)

    private func makeTextView(_ s: String) -> EditorTextView {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = s
        return tv
    }

    /// 由于  / NSTextView 不能有多个长度为 0 的范围，因此插入符序列是通过专用插槽输入的。
    private func setCarets(_ tv: EditorTextView, _ ranges: [NSRange]) {
        tv._testSetCarets(ranges)
    }

    func testTypingInsertsAtEveryCaret() {
        let tv = makeTextView("aaa\nbbb\nccc")
        setCarets(tv, [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0),
                       NSRange(location: 8, length: 0)])
        tv.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "- aaa\n- bbb\n- ccc")
        // 光标移动到插入字符串的直接位置。
        XCTAssertEqual(tv._testCarets,
                       [NSRange(location: 2, length: 0), NSRange(location: 8, length: 0),
                        NSRange(location: 14, length: 0)])
    }

    /// 当有多个选项时，每个选项都会被替换（该过程涉及收集带有 ⌘D 的单词，然后重新输入它们）。
    func testTypingReplacesEverySelection() {
        let tv = makeTextView("foo bar foo")
        setCarets(tv, [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        tv.insertText("qux", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "qux bar qux")
    }

    func testDeleteBackwardAtEveryCaret() {
        let tv = makeTextView("a1b\na2b")
        setCarets(tv, [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, "ab\nab")
    }

    func testSingleCaretKeepsStandardBehaviour() {
        let tv = makeTextView("abc")
        setCarets(tv, [NSRange(location: 3, length: 0)])
        tv.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "abcd")
        XCTAssertFalse(tv.hasMultipleCarets)
    }

    func testSelectNextOccurrenceGrowsSelectionThenEscapeCollapses() {
        let tv = makeTextView("foo bar foo baz foo")
        setCarets(tv, [NSRange(location: 1, length: 0)])   // 第一个 foo 内部
        tv.selectNextOccurrence()                          // 掌握这个词
        XCTAssertEqual(tv._testCarets, [NSRange(location: 0, length: 3)])
        tv.selectNextOccurrence()                          // 第二个
        tv.selectNextOccurrence()                          // 第三个
        XCTAssertEqual(tv._testCarets.count, 3)
        XCTAssertTrue(tv.hasMultipleCarets)

        tv.cancelOperation(nil)                            // Esc 到单个
        XCTAssertFalse(tv.hasMultipleCarets)
    }

    func testAddCaretBelowThenTypeHitsBothLines() {
        let tv = makeTextView("abc\ndef")
        setCarets(tv, [NSRange(location: 0, length: 0)])
        tv.addCaret(above: false)
        tv.insertText("#", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "#abc\n#def")
    }

    // MARK: - 序列号参数化

    func testNumberLinesDefaultsMatchPlainTransform() {
        let source = "a\nb\nc\n"
        XCTAssertEqual(LineNumberer.number(source, options: .init()), "1\ta\n2\tb\n3\tc\n")
        XCTAssertEqual(TextTransform.numberLines.apply(source), LineNumberer.number(source, options: .init()))
    }

    func testNumberLinesStartStepAndPad() {
        let opts = LineNumberer.Options(start: 10, step: 5, padWidth: 4, separator: ": ")
        XCTAssertEqual(LineNumberer.number("a\nb\nc", options: opts), "0010: a\n0015: b\n0020: c")
    }

    func testNumberLinesNegativeStepAndSign() {
        let opts = LineNumberer.Options(start: 1, step: -2, padWidth: 3, separator: " ")
        XCTAssertEqual(LineNumberer.number("a\nb\nc", options: opts), "001 a\n-001 b\n-003 c")
    }

    /// 分隔符可以使用与拆分对话框中相同的转义字符（日语键盘上的 `\t` / `¥t`）来编写。
    func testNumberLinesSeparatorEscapes() {
        XCTAssertEqual(LineNumberer.number("a", options: .init(separator: "\\t")), "1\ta")
        XCTAssertEqual(LineNumberer.number("a", options: .init(separator: "¥t")), "1\ta")
    }

    func testNumberLinesKeepsTrailingNewline() {
        XCTAssertEqual(LineNumberer.number("a\nb", options: .init()), "1\ta\n2\tb")
        XCTAssertEqual(LineNumberer.number("a\nb\n", options: .init()), "1\ta\n2\tb\n")
    }

    // MARK: - 更换外壳维护

    func testPreserveCaseAppliesMatchedShape() {
        XCTAssertEqual(CasePreserving.apply("timeout", matching: "DEADLINE"), "TIMEOUT")
        XCTAssertEqual(CasePreserving.apply("timeout", matching: "deadline"), "timeout")
        XCTAssertEqual(CasePreserving.apply("timeout", matching: "Deadline"), "Timeout")
    }

    /// 对于无法识别的拼写（camelCase、仅符号、日文字符），将按原样使用替换字符串。
    func testPreserveCaseLeavesMixedAlone() {
        XCTAssertEqual(CasePreserving.apply("newValue", matching: "oldValue"), "newValue")
        XCTAssertEqual(CasePreserving.apply("newValue", matching: "---"), "newValue")
        XCTAssertEqual(CasePreserving.apply("newValue", matching: "見出し"), "newValue")
    }

    /// 即使替换字符串不是以英文字母开头，也只需将第一个英文字母大写即可。
    func testPreserveCaseCapitalizesFirstLetterOnly() {
        XCTAssertEqual(CasePreserving.apply("_value", matching: "Old"), "_Value")
        XCTAssertEqual(CasePreserving.apply("", matching: "Old"), "")
    }

    func testPreserveCaseStyleDetection() {
        XCTAssertEqual(CasePreserving.style(of: "ABC"), .upper)
        XCTAssertEqual(CasePreserving.style(of: "abc"), .lower)
        XCTAssertEqual(CasePreserving.style(of: "Abc"), .capitalized)
        XCTAssertEqual(CasePreserving.style(of: "aBc"), .mixed)
        XCTAssertEqual(CasePreserving.style(of: "123"), .mixed)
    }
}

