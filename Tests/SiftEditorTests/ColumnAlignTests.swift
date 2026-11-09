import XCTest
@testable import SiftEditorCore

/// 将第一行创建的数字除法应用于其余行。
///
/// **如果此操作失败，最终结果将是“数据看起来对齐但实际上未对齐”** -- 因为它看起来是对齐的，
/// 质量本来就很差。务必小心，不要擦除字符，并计算两位数全角字符的数量。
final class ColumnAlignTests: XCTestCase {

    private let starts = [1, 9, 15]   // 1-8 / 9-14 / 15-

    func testAlignsSpaceSeparatedLines() {
        let src = "123 TOKYO 20260815\n4567 OSAKA 20260101\n"
        XCTAssertEqual(ColumnAlign.align(src, to: starts),
                       "123     TOKYO 20260815\n4567    OSAKA 20260101\n")
    }

    func testAlignsTabSeparatedLines() {
        XCTAssertEqual(ColumnAlign.alignLine("12\tOSAKA\t20260101", to: starts),
                       "12      OSAKA 20260101")
        XCTAssertFalse(ColumnAlign.alignLine("12\tOSAKA", to: starts).contains("\t"),
                       "タブは残さない（固定長に混ざると桁が崩れる）")
    }

    /// 已完成的行保持不变（即使重新应用也不会出错）。
    func testAlreadyAlignedStaysPut() {
        let line = "123     TOKYO 20260815"
        XCTAssertEqual(ColumnAlign.alignLine(line, to: starts), line)
    }

    /// **请勿删除字符。** 如果项目位数超过限制，请留一个空格并继续。
    func testOverlongFieldPushesInsteadOfTruncating() {
        XCTAssertEqual(ColumnAlign.alignLine("123456789012 OSAKA 20260101", to: starts),
                       "123456789012 OSAKA 20260101")
        XCTAssertTrue(ColumnAlign.alignLine("123456789012 OSAKA", to: starts).contains("123456789012"))
    }

    /// 如果项目数超过定义数量，则将剩余部分添加到末尾，并在末尾添加空格 1（不要截断）。
    func testExtraTokensAreKept() {
        XCTAssertEqual(ColumnAlign.alignLine("1 A B C D", to: starts),
                       "1       A     B C D")
    }

    /// 项目较少的行应在此处结束（不留任何空格）。
    func testFewerTokensLeaveNoTrailingSpaces() {
        XCTAssertEqual(ColumnAlign.alignLine("1 A", to: starts), "1       A")
    }

    /// 这些数字代表显示宽度（全角 = 2）。如果按字符数调整，则只有包含全角字符的行将无法对齐。
    func testFullWidthCountsAsTwoColumns() {
        // 东京 = 4 位数字。第 5 位和第 6 位数字用空格填充，第 7 位数字为 A。
        XCTAssertEqual(ColumnAlign.alignLine("東京 A", to: [1, 7]), "東京  A")
    }

    func testEmptyAndBlankLinesUntouched() {
        XCTAssertEqual(ColumnAlign.align("\n\n", to: starts), "\n\n")
        XCTAssertEqual(ColumnAlign.alignLine("   ", to: starts), "   ")
    }

    /// 保留换行符和 CRLF 的残余。
    func testKeepsLineEndings() {
        XCTAssertEqual(ColumnAlign.align("1 A", to: starts), "1       A", "末尾に改行を足さない")
        XCTAssertEqual(ColumnAlign.alignLine("1 A\r", to: starts), "1       A\r")
    }

    // MARK: - 根据内容创建数字除法（突然 ⌥Tab）

    /// 将每个项目除以可容纳最长项目的宽度，并在两者之间留出一位数字的空格。
    func testInfersStartsFromContent() {
        let lines = ["123 TOKYO 20260815", "4567 OSAKA 20260101", "89 NAGOYA 20251231"]
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: lines), [1, 6, 13])
        // 当使用创建的列间距进行对齐时，任何行中都不会出现项目重叠的情况。
        let aligned = lines.map { ColumnAlign.alignLine($0, to: [1, 6, 13]) }
        XCTAssertEqual(aligned, ["123  TOKYO  20260815",
                                 "4567 OSAKA  20260101",
                                 "89   NAGOYA 20251231"])
    }

    /// 全角字符也算作 2 位数字。
    func testInferCountsFullWidth() {
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: ["東京 A", "大阪府 B"]), [1, 8])
    }

    /// 如果只有一个项目，则不要分割（分割没有意义）。
    func testInferNeedsAtLeastTwoFields() {
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: ["abc", "de"]), [])
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: []), [])
    }

    func testNoFieldStartsIsNoOp() {
        XCTAssertEqual(ColumnAlign.align("1 A\n", to: []), "1 A\n")
    }
}
