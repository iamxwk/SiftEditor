import XCTest
@testable import SiftEditorCore

/// 验证数字标尺 (A) 和数字导轨 (B) 的坐标计算和导轨保持是否为数组。
///
/// 这是两个窗格中唯一共同的表达式，因此**请确保数字 ↔ x 之间的转换没有中断**
/// 查看最厚的部分。如果您将固定长度的项目定义 (C) 与错位对齐，则同一个文件将
/// 重新打开页面会导致该项目指向不同的位置。
final class ColumnRulerTests: XCTestCase {

    private let w: CGFloat = 8   // 等宽，1 位数字宽度

    // MARK: - 桁 ↔ x

    func testColumnOneStartsAtOrigin() {
        XCTAssertEqual(ColumnRuler.x(ofColumn: 1, columnWidth: w), 0)
    }

    func testColumnXIsOneBased() {
        XCTAssertEqual(ColumnRuler.x(ofColumn: 9, columnWidth: w), 64)
    }

    func testColumnAtXIsOneBased() {
        XCTAssertEqual(ColumnRuler.column(atX: 0, columnWidth: w), 1)
        XCTAssertEqual(ColumnRuler.column(atX: 7.9, columnWidth: w), 1)
        XCTAssertEqual(ColumnRuler.column(atX: 8, columnWidth: w), 2)
        XCTAssertEqual(ColumnRuler.column(atX: 64, columnWidth: w), 9)
    }

    /// 数字 → x → 数字必须返回到所有数字（如果来回移动后没有返回到同一个数字，则通过单击放置）
    /// （指南附在另一个数字上）。
    func testRoundTripColumnToXToColumn() {
        for col in 1...500 {
            let x = ColumnRuler.x(ofColumn: col, columnWidth: w)
            XCTAssertEqual(ColumnRuler.column(atX: x, columnWidth: w), col, "桁 \(col) で往復が壊れた")
        }
    }

    func testNegativeXClampsToFirstColumn() {
        XCTAssertEqual(ColumnRuler.column(atX: -100, columnWidth: w), 1)
    }

    func testZeroColumnWidthDoesNotDivideByZero() {
        XCTAssertEqual(ColumnRuler.column(atX: 100, columnWidth: 0), 1)
        XCTAssertTrue(ColumnRuler.ticks(offset: 0, width: 100, columnWidth: 0).isEmpty)
    }

    // MARK: - 秤

    func testTicksIncludeFirstColumnAsMajor() {
        let ticks = ColumnRuler.ticks(offset: 0, width: 100, columnWidth: w)
        XCTAssertEqual(ticks.first?.column, 1)
        XCTAssertEqual(ticks.first?.isMajor, true)
    }

    func testTicksAreMajorEveryTenAndMinorEveryFive() {
        let ticks = ColumnRuler.ticks(offset: 0, width: 240, columnWidth: w)
        let majors = ticks.filter(\.isMajor).map(\.column)
        let minors = ticks.filter { !$0.isMajor }.map(\.column)
        XCTAssertEqual(majors, [1, 10, 20, 30])
        XCTAssertEqual(minors, [5, 15, 25])
    }

    /// 水平滚动时，刻度向左移动，但**数字不会移动**。
    func testTicksFollowHorizontalOffset() {
        let ticks = ColumnRuler.ticks(offset: 800, width: 100, columnWidth: w)
        XCTAssertEqual(ticks.first?.column, 105)   // x=800 是第 101 位数字，第一个刻度线是 105。
        // x 保留其绝对坐标系，文本左边缘为 0（调用方减去 offset）。
        XCTAssertEqual(ticks.first?.x, ColumnRuler.x(ofColumn: 105, columnWidth: w))
    }

    func testTicksEmptyForZeroWidth() {
        XCTAssertTrue(ColumnRuler.ticks(offset: 0, width: 0, columnWidth: w).isEmpty)
    }

    // MARK: - 指南是“数字排列”

    func testGuidesAreSortedUniqueAndOneBased() {
        let g = ColumnGuides([15, 9, 15, 0, -3, 1])
        XCTAssertEqual(g.columns, [1, 9, 15])
    }

    func testToggleAddsAndRemoves() {
        var g = ColumnGuides()
        g.toggle(9)
        XCTAssertEqual(g.columns, [9])
        g.toggle(1)
        XCTAssertEqual(g.columns, [1, 9], "足したら昇順に保たれる")
        g.toggle(9)
        XCTAssertEqual(g.columns, [1])
    }

    func testInsertIgnoresDuplicatesAndZero() {
        var g = ColumnGuides([5])
        g.insert(5)
        g.insert(0)
        XCTAssertEqual(g.columns, [5])
    }

    func testRemoveAllClears() {
        var g = ColumnGuides([1, 2, 3])
        g.removeAll()
        XCTAssertTrue(g.isEmpty)
    }

    /// 点击命中检测。防止以像素级精度瞄准细线。
    func testNearestWithinTolerance() {
        let g = ColumnGuides([10, 40])
        XCTAssertEqual(g.nearest(to: 11, within: 1), 10)
        XCTAssertEqual(g.nearest(to: 12, within: 1), nil)
        XCTAssertEqual(g.nearest(to: 12, within: 2), 10)
        XCTAssertNil(ColumnGuides().nearest(to: 10, within: 5))
    }

    func testNearestPrefersSmallerColumnOnTie() {
        let g = ColumnGuides([9, 11])
        XCTAssertEqual(g.nearest(to: 10, within: 1), 9)
    }

    // MARK: - C（固定长度项目定义）

    /// 数字 [9, 15] 由三部分组成：“1-8 / 9-14 / 15-”。最后一部分只有在确定行长度后才会闭合。
    func testFieldRangesFromGuides() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.fieldRanges(lastColumn: 40), [1...8, 9...14, 15...40])
    }

    func testFieldRangesDropOpenTailWithoutLastColumn() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.fieldRanges(), [1...8, 9...14])
    }

    func testFieldRangesIgnoreGuideAtColumnOne() {
        // 指南的第一个数字不是“分隔符”（因为它是开头，它不会分割项目）。
        let g = ColumnGuides([1, 9])
        XCTAssertEqual(g.fieldRanges(lastColumn: 20), [1...8, 9...20])
    }

    func testFieldRangesEmptyWithoutGuidesOrLength() {
        XCTAssertEqual(ColumnGuides().fieldRanges(), [])
        XCTAssertEqual(ColumnGuides().fieldRanges(lastColumn: 10), [1...10])
    }

    // MARK: - 两个窗格读取的数字宽度相同。

    /// 标尺刻度线宽度和块光标宽度相同：“等宽，1 个字符”。
    /// 单独测量时，刻度和文字略有错位。
    func testColumnWidthMatchesCaretWidth() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(EditorStyle.columnWidth(for: font), EditorStyle.caretWidth(for: font))
    }

    func testColumnWidthIsPositiveForProportionalFont() {
        let font = NSFont.systemFont(ofSize: 13)
        XCTAssertGreaterThan(EditorStyle.columnWidth(for: font), 0)
    }
}
