import XCTest
import AppKit
@testable import SiftEditorCore

/// 当有数字引导时，Tab 表示“在下一个数字前填充空格”。
///
/// **我想要的不是光标跳动，而是列对齐。** 就像文字处理器中的制表符位置一样。
/// 如果在打字时按下 Tab，则后面的字符将移动到该位置。
final class FieldTabTests: XCTestCase {

    private func pane(_ text: String, guides: [Int]) -> EditableViewer {
        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v._testSetText(text)
        v.setColumnGuides(guides)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    /// 在未完成的行上按 Tab 键，会在下一列之前插入空格，导致字符发生偏移。
    func testTabPadsToNextFieldStart() {
        let v = pane("123\n", guides: [9, 15])
        v._testSelect(NSRange(location: 3, length: 0))     // ，紧随“123”之后 = 第 4 位数字
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testText, "123     \n", "9 桁目まで空白 5 つ")
        XCTAssertEqual(v._testSelection.location, 8)
    }

    /// 如果后面有字符，则该字符移至下一个数字（这很明显，因为这是一个插入操作，但这是要求）。
    func testTabShiftsFollowingText() {
        let v = pane("12TOKYO\n", guides: [9])
        v._testSelect(NSRange(location: 2, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testText, "12      TOKYO\n", "TOKYO が 9 桁目へずれる")
    }

    /// **请勿包含制表符。** 如果固定长度的字符串中混入制表符，则其他工具读取该字符串时，数字将会损坏。
    func testTabNeverInsertsATabCharacter() {
        let v = pane("1\n", guides: [5])
        v._testSelect(NSRange(location: 1, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertFalse(v._testText.contains("\t"))
        XCTAssertEqual(v._testText, "1   \n")
    }

    /// 这些数字代表显示宽度（全角 = 2）。如果按字符数调整，则只有包含全角字符的行将无法对齐。
    func testPadsByDisplayWidth() {
        let v = pane("東京\n", guides: [7])       // 2 个全角字符 = 4 位数字
        v._testSelect(NSRange(location: 2, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testText, "東京  \n", "5・6 桁目を空白で埋めて 7 桁目へ")
    }

    /// ⇧Tab 删除空格键，直到**上一个项目的数字位数**（但不会删除字符）。
    func testBacktabRemovesPaddingOnly() {
        let v = pane("123     \n", guides: [9, 15])
        v._testSelect(NSRange(location: 8, length: 0))
        XCTAssertTrue(v._testFieldTab(backwards: true))
        XCTAssertEqual(v._testText, "123\n", "空白だけが消える")

        let v2 = pane("12345678ABC\n", guides: [9])
        v2._testSelect(NSRange(location: 11, length: 0))
        XCTAssertTrue(v2._testFieldTab(backwards: true))
        XCTAssertEqual(v2._testText, "12345678ABC\n", "空白でない字は消さない")
    }

    /// 不要压缩到最后一个项目右侧（以防止该行无限延伸）。
    func testNoPaddingPastTheLastField() {
        let v = pane("12345678ABCDEF0123\n", guides: [9, 15])
        v._testSelect(NSRange(location: 18, length: 0))
        XCTAssertTrue(v._testFieldTab(), "受けはするが")
        XCTAssertEqual(v._testText, "12345678ABCDEF0123\n", "本文は変わらない")
    }

    /// 没有指南将不被接受 = **制表符将像以前一样包含在内**。
    func testNoGuidesFallsBackToTabCharacter() {
        XCTAssertFalse(pane("00012345TOKYO\n", guides: [])._testFieldTab())
        XCTAssertFalse(pane("abc\n", guides: [1])._testFieldTab(), "1 桁目のガイドは切れ目ではない")
    }

    // MARK: - 将第一行的数字分配到剩余的行中。

    /// **这才是真正的操作。** 将第一行格式化为 Tab 后，对所有行应用相同的数字除法。
    func testAlignAppliesTheLayoutToEveryLine() {
        let v = pane("123 TOKYO 20260815\n4567 OSAKA 20260101\n89 NAGOYA 20251231\n", guides: [9, 15])
        XCTAssertTrue(v.alignToColumnGuides())
        XCTAssertEqual(v._testText,
                       "123     TOKYO 20260815\n4567    OSAKA 20260101\n89      NAGOYA 20251231\n")
    }

    /// 如果进行了选择，则仅显示符合该选择的行（不要在行中间断开）。
    func testAlignOnlyTouchesSelectedLines() {
        let v = pane("123 TOKYO\n4567 OSAKA\n", guides: [9])
        v._testSelect(NSRange(location: 2, length: 2))     // 仅选择第一行的中间部分
        XCTAssertTrue(v.alignToColumnGuides())
        XCTAssertEqual(v._testText, "123     TOKYO\n4567 OSAKA\n", "2 行目は触らない")
    }

    /// 1 撤销功能返回到先前的状态（即使应用了数百行，也只会返回一次）。
    func testAlignIsOneUndo() {
        let v = pane("1 A\n2 B\n", guides: [9])
        v.alignToColumnGuides()
        XCTAssertEqual(v._testText, "1       A\n2       B\n")
        v._testUndo()
        XCTAssertEqual(v._testText, "1 A\n2 B\n")
    }

    /// 如果没有中断，则什么也不做。
    func testAlignNeedsBoundaries() {
        XCTAssertFalse(pane("1 A\n", guides: [])._testText.isEmpty)
        XCTAssertFalse(pane("1 A\n", guides: []).alignToColumnGuides())
    }

    // MARK: - 顺序无关紧要（以⌥Tab 开头 / 以 Tab 开头）

    /// **即使不画线，⌥Tab 也能通过。** 从内容创建数字分割线并对齐所有线条。
    /// 还会显示标尺，以便可以看到您创建的线条。
    func testAlignWithoutGuidesInfersLayout() {
        let v = pane("123 TOKYO 20260815\n4567 OSAKA 20260101\n", guides: [])
        XCTAssertTrue(v.alignToColumnGuides())
        XCTAssertEqual(v._testText, "123  TOKYO 20260815\n4567 OSAKA 20260101\n")
        XCTAssertEqual(v.columnGuideColumns, [6, 12], "作った切れ目が残る")
        XCTAssertTrue(v.columnRulerVisible, "引いた線が見えるようにルーラーも出る")
    }

    /// **即使您不画线，Tab 也会在该位置创建一个断点。** 同时还会出现一个标尺。
    func testTabWithoutGuidesCreatesBoundary() {
        let v = pane("123TOKYO\n", guides: [])
        v._testSelect(NSRange(location: 3, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v.columnGuideColumns, [4], "4 桁目が切れ目になる")
        XCTAssertTrue(v.columnRulerVisible)
        XCTAssertEqual(v._testText, "123TOKYO\n", "本文はまだ動かない（切れ目を置いただけ）")
    }

    /// 不要在行的开头创建换行符（即第一个项目的开头，不构成换行符）。
    func testTabAtLineStartDoesNotCreateBoundary() {
        let v = pane("123\n", guides: [])
        v._testSelect(NSRange(location: 0, length: 0))
        XCTAssertFalse(v._testFieldTab(), "受けない＝今までどおりタブ文字が入る")
    }

    /// 即使标尺是闭合的，当您用 Tab 填充它时，它也会显示出来（这样您就可以看到您达到了哪个数字）。
    func testTabShowsTheRuler() {
        let v = pane("123\n", guides: [9])
        XCTAssertFalse(v.columnRulerVisible)
        v._testSelect(NSRange(location: 3, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertTrue(v.columnRulerVisible)
    }

    // MARK: - 尺子右边缘的导向线

    /// **⌥Tab** 仅当存在需要实际更改的行时才会显示。** 对齐完成后，它将消失。
    func testHintAppearsOnlyWhileThereIsSomethingToAlign() {
        let v = pane("123 TOKYO\n4567 OSAKA\n", guides: [9])
        XCTAssertNotNil(v._testRulerHint, "まだ揃っていないので出す")
        v.alignToColumnGuides()
        XCTAssertNil(v._testRulerHint, "揃えたら消える")
    }

    func testNoHintWithoutGuides() {
        XCTAssertNil(pane("123 TOKYO\n", guides: [])._testRulerHint)
        XCTAssertNil(pane("123 TOKYO\n", guides: [1])._testRulerHint, "1 桁目は切れ目ではない")
    }

    /// 已填充的内容可以撤销。
    func testPaddingIsOneUndo() {
        let v = pane("123\n", guides: [9])
        v._testSelect(NSRange(location: 3, length: 0))
        v._testFieldTab()
        XCTAssertEqual(v._testText, "123     \n")
        v._testUndo()
        XCTAssertEqual(v._testText, "123\n")
    }
}
