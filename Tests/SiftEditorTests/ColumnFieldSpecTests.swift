import XCTest
@testable import SiftEditorCore

/// 固定长度项目定义 (C) 的纯逻辑 - 字符串 ↔ 边界数字，在数字处截断，测量宽度。
///
/// **这是“了解规格的人”的入口点**，所以我将默默地展示一部分难以辨认的文字。
/// 最重要的是不要让它通过（如果部分通过，错误的字段定义会导致对数据的误解）。
final class ColumnFieldSpecTests: XCTestCase {

    // MARK: - 字符串 → 边界数字

    func testParsesClosedFields() {
        // 1-8 / 9-14 / 15-40 的断点分别位于 9 和 15，标记 41 的结束点位于 40。
        XCTAssertEqual(ColumnFieldSpec.parse("1-8,9-14,15-40"), [9, 15, 41])
    }

    func testParsesOpenLastField() {
        XCTAssertEqual(ColumnFieldSpec.parse("1-8,9-14,15-"), [9, 15])
    }

    func testBareNumbersAreFieldStarts() {
        XCTAssertEqual(ColumnFieldSpec.parse("1,9,15"), [9, 15])
    }

    func testAcceptsSpacesAndFullWidthPunctuation() {
        XCTAssertEqual(ColumnFieldSpec.parse(" 1-8 , 9-14 "), ColumnFieldSpec.parse("1-8,9-14"))
        XCTAssertEqual(ColumnFieldSpec.parse("１-８，９-１４"), ColumnFieldSpec.parse("1-8,9-14"))
        XCTAssertEqual(ColumnFieldSpec.parse("1〜8、9〜14"), ColumnFieldSpec.parse("1-8,9-14"))
    }

    func testGapBecomesItsOwnField() {
        // 第 1-8 节和第 15-20 节（9-14 节）之间的部分不应丢弃，而应作为单独的项目保留。
        XCTAssertEqual(ColumnFieldSpec.parse("1-8,15-20"), [9, 15, 21])
    }

    func testEmptyMeansNoDefinition() {
        XCTAssertEqual(ColumnFieldSpec.parse(""), [])
        XCTAssertEqual(ColumnFieldSpec.parse("   "), [])
    }

    /// 无法识别的字符为 nil。**仅部分字符被屏蔽。**
    func testRejectsMalformed() {
        XCTAssertNil(ColumnFieldSpec.parse("abc"))
        XCTAssertNil(ColumnFieldSpec.parse("1-8,x-14"))
        XCTAssertNil(ColumnFieldSpec.parse("-8"))
        XCTAssertNil(ColumnFieldSpec.parse("0-8"))
        XCTAssertNil(ColumnFieldSpec.parse("8-1"))          // 反向
        XCTAssertNil(ColumnFieldSpec.parse("1-8,5-12"))     // 重叠
        XCTAssertNil(ColumnFieldSpec.parse("9-14,1-8"))     // 数字已重置。
        XCTAssertNil(ColumnFieldSpec.parse("1-999999"))     // 超出限制
    }

    // MARK: - 边界数字 → 字符串（往返）

    func testTextForGuidesLeavesLastFieldOpen() {
        XCTAssertEqual(ColumnFieldSpec.text(for: ColumnGuides([9, 15])), "1-8,9-14,15-")
        XCTAssertEqual(ColumnFieldSpec.text(for: ColumnGuides()), "")
    }

    /// 即使打开对话框并按 OK 而不进行任何更改，定义也不会改变。
    func testRoundTripThroughText() {
        for columns in [[9, 15], [9, 15, 41], [2], [3, 4, 5]] {
            let text = ColumnFieldSpec.text(for: ColumnGuides(columns))
            XCTAssertEqual(ColumnFieldSpec.parse(text), columns, "『\(text)』で往復が壊れた")
        }
    }

    // MARK: - 项目范围（闭合末尾以匹配数据）

    func testFieldRangesFitSampleLines() {
        let guides = ColumnGuides([9, 15])
        XCTAssertEqual(guides.fieldRanges(fitting: ["12345678ABCDEF0123456789"]), [1...8, 9...14, 15...24])
    }

    /// 宽度以**可见数字**为准（全角=2），而非字符数。以字符数测量会导致与参考线错位。
    func testFieldRangesMeasureDisplayColumns() {
        let guides = ColumnGuides([5])
        XCTAssertEqual(guides.fieldRanges(fitting: ["日本語"]), [1...4, 5...6])
    }

    // MARK: - 按数字切割

    private func formatter(_ guides: [Int], _ lines: [String]) -> TabularFormatter {
        TabularFormatter.build(mode: .fixedWidth, sampleLines: lines,
                               fields: ColumnGuides(guides).fieldRanges(fitting: lines))
    }

    func testFixedCellsSliceByColumns() {
        let line = "00012345TOKYO 20260815"
        let fmt = formatter([9, 15], [line])
        XCTAssertEqual(fmt.cells(of: line), ["00012345", "TOKYO", "20260815"])
    }

    func testShortLineGivesEmptyTrailingCells() {
        let fmt = formatter([9, 15], ["00012345TOKYO 20260815"])
        XCTAssertEqual(fmt.cells(of: "0001"), ["0001", "", ""])
    }

    /// 全角字符为 2 位数字。跨越多位数字的单个字符应放置在**起始边**字段中（不要拆分字符）。
    func testWideCharactersCountAsTwoColumns() {
        let fmt = formatter([5], ["日本語です"])
        XCTAssertEqual(fmt.cells(of: "日本語です"), ["日本", "語です"])
        // ：从第 3 位数字（第 2 位到第 3 位数字）开始的全角字符保留在边界 5 之前的一侧。
        XCTAssertEqual(fmt.cells(of: "A日本語"), ["A日本", "語"])
    }

    func testColumnNamesAreTheColumnsThemselves() {
        let fmt = formatter([9, 15], ["00012345TOKYO 20260815"])
        XCTAssertEqual(fmt.columns.map(\.key), ["1-8", "9-14", "15-22"])
    }

    /// 如果没有定义，则不会创建该列（调用者会先询问）。
    func testNoFieldsMeansNoColumns() {
        let fmt = TabularFormatter.build(mode: .fixedWidth, sampleLines: ["abc"], fields: [])
        XCTAssertEqual(fmt.columnCount, 0)
    }

    /// 这是一个用于计数数字的显示器，因此它不会在宽度限制处被截断（CSV 被截断为 40 位数字）。
    func testWideFieldIsNotTruncated() {
        let long = String(repeating: "A", count: 60)
        let fmt = TabularFormatter.build(mode: .fixedWidth, sampleLines: [long], fields: [1...60])
        XCTAssertEqual(fmt.format(long), long)
    }

    /// 即使定义延伸到数据的右侧，也不要添加空列。
    func testDefinitionBeyondDataDoesNotAddEmptyColumn() {
        let guides = ColumnGuides([9, 15, 41])       // 1-8,9-14,15-40
        XCTAssertEqual(guides.fieldRanges(fitting: [String(repeating: "X", count: 40)]),
                       [1...8, 9...14, 15...40])
    }

    func testFormatAlignsCellsWithSeparator() {
        let lines = ["00012345TOKYO 20260815", "00000007OSAKA 20260101"]
        let fmt = formatter([9, 15], lines)
        XCTAssertEqual(fmt.format(lines[0]), "00012345 │ TOKYO │ 20260815")
        XCTAssertEqual(fmt.format(lines[1]), "00000007 │ OSAKA │ 20260101")
    }

    // MARK: - 条纹（绘制一条线将创建行）

    /// 每隔一个字母着色。**不要给第一个字母着色**（如果颜色突然从文本的左边缘开始，
    /// 似乎已选中某些内容。
    func testStripesArePaintedEveryOtherField() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.stripes(upTo: 22), [9...14])
        XCTAssertEqual(g.fieldRanges(lastColumn: 22), [1...8, 9...14, 15...22])
    }

    func testStripesFollowMoreGuides() {
        let g = ColumnGuides([5, 9, 13, 17])
        XCTAssertEqual(g.stripes(upTo: 20), [5...8, 13...16])
    }

    /// 如果没有线条，则不填充（出现条纹 = 已绘制线条，与之对应）。
    func testNoGuidesNoStripes() {
        XCTAssertTrue(ColumnGuides().stripes(upTo: 40).isEmpty)
        XCTAssertTrue(ColumnGuides([1]).stripes(upTo: 40).isEmpty, "1 桁目は切れ目ではない")
    }

    /// 只给屏幕右边缘着色（不要给不可见的数字着色）。
    func testStripesStopAtVisibleColumn() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.stripes(upTo: 12), [9...12])
        XCTAssertTrue(g.stripes(upTo: 5).isEmpty)
    }

    // 使用  MARK: - Tab 浏览项目

    func testFieldStartsAlwaysBeginAtOne() {
        XCTAssertEqual(ColumnGuides([9, 15]).fieldStarts, [1, 9, 15])
        XCTAssertEqual(ColumnGuides().fieldStarts, [1])
        XCTAssertEqual(ColumnGuides([1, 9]).fieldStarts, [1, 9], "1 桁目を二重に数えない")
    }

    func testTabMovesToNextFieldStart() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.nextFieldStart(after: 1), 9)
        XCTAssertEqual(g.nextFieldStart(after: 8), 9)
        XCTAssertEqual(g.nextFieldStart(after: 9), 15)
        XCTAssertNil(g.nextFieldStart(after: 15), "最後の項目からは次の行へ送る")
        XCTAssertNil(g.nextFieldStart(after: 40))
    }

    func testShiftTabMovesToPreviousFieldStart() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.previousFieldStart(before: 20), 15)
        XCTAssertEqual(g.previousFieldStart(before: 15), 9)
        XCTAssertEqual(g.previousFieldStart(before: 9), 1)
        XCTAssertNil(g.previousFieldStart(before: 1), "最初の項目からは前の行へ送る")
    }

    // MARK: - 您目前位于哪个部分？（统治者腰带）

    func testFieldRangeContainingColumn() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.fieldRange(containing: 1, lastColumn: 22), 1...8)
        XCTAssertEqual(g.fieldRange(containing: 8, lastColumn: 22), 1...8)
        XCTAssertEqual(g.fieldRange(containing: 9, lastColumn: 22), 9...14)
        XCTAssertEqual(g.fieldRange(containing: 15, lastColumn: 22), 15...22, "最後の項目は本文の端で閉じる")
        XCTAssertEqual(g.fieldRange(containing: 30, lastColumn: 22), 15...30, "本文より右でも帯を作れる")
    }

    func testNoFieldRangeWithoutBoundaries() {
        XCTAssertNil(ColumnGuides().fieldRange(containing: 5, lastColumn: 22))
        XCTAssertNil(ColumnGuides([1]).fieldRange(containing: 5, lastColumn: 22))
    }

    // MARK: - 抓住导轨并移动它

    func testMoveGuide() {
        var g = ColumnGuides([9, 15])
        XCTAssertTrue(g.move(9, to: 10))
        XCTAssertEqual(g.columns, [10, 15])
    }

    /// 如果目的地已被占用，请勿移动（如果重叠，其中一个将会消失，并且您将无法将其移回）。
    func testMoveOntoExistingGuideIsRefused() {
        var g = ColumnGuides([9, 15])
        XCTAssertFalse(g.move(9, to: 15))
        XCTAssertEqual(g.columns, [9, 15])
    }

    func testMoveUnknownOrInvalidColumnIsRefused() {
        var g = ColumnGuides([9])
        XCTAssertFalse(g.move(8, to: 12))
        XCTAssertFalse(g.move(9, to: 0))
        XCTAssertEqual(g.columns, [9])
    }
}
