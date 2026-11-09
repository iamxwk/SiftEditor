import XCTest
@testable import SiftEditorCore

/// “比较格式”的规范化。
///
/// **此功能的一次性请求**是“测试环境和生产环境中的数据内容不同，但日期格式不同”。
/// 我想看看它们是否都在那里。” 因此，只有两处房产需要保护。
/// **仅值不同的行将被视为相同 / 形状不同的行将保持不同**。
final class FormatMaskTests: XCTestCase {

    private let mask = FormatMask.standard

    // MARK: - 保留形状，删除值。

    func testSameFormatDifferentValuesCollapse() {
        XCTAssertEqual(mask.masked("2026-08-19"), mask.masked("1999-01-02"))
        XCTAssertEqual(mask.masked("2026-08-19 12:00:00 ERROR uid=41"),
                       mask.masked("2001-12-31 03:59:07 WARN uid=88"))
        // 默认情况下，空格的数量是“形状”的一部分（如果列未对齐，则会显示为差异）。
        XCTAssertNotEqual(mask.masked("ERROR uid=41"), mask.masked("WARN  uid=88"))
    }

    /// **如果此操作失败，则该函数本身将变得毫无价值。** 如果实现将其替换为类型名称 (`<DATE>`)，
    /// 甚至格式上的差异也消失了，这部分内容通过了。
    func testDifferentDateFormatsStayDifferent() {
        XCTAssertNotEqual(mask.masked("2026-08-19"), mask.masked("2026/08/19"))
        XCTAssertNotEqual(mask.masked("2026-08-19"), mask.masked("19-08-2026 "))
        XCTAssertNotEqual(mask.masked("2026-08-19T12:00:00Z"), mask.masked("2026-08-19 12:00:00"))
        // syslog (Jul 30 12:34:56) 和 ISO 是不同的形式。
        XCTAssertNotEqual(mask.masked("Aug 19 12:00:00"), mask.masked("2026-08-19 12:00:00"))
    }

    func testMaskedShape() {
        XCTAssertEqual(mask.masked("2026-08-19 12:00:00"), "9999-99-99 99:99:99")
        XCTAssertEqual(mask.masked("ERROR"), "A")
        XCTAssertEqual(mask.masked("uid=41,name=Ann"), "A=99,A=A")
    }

    // MARK: - 数字（零填充以弥补差异）

    func testZeroPaddingIsADifferenceByDefault() {
        XCTAssertNotEqual(mask.masked("007"), mask.masked("7"))
        XCTAssertEqual(mask.masked("007"), mask.masked("123"))
    }

    func testDigitCountIgnoresPadding() {
        let m: FormatMask = [.digits, .digitCount, .letters]
        XCTAssertEqual(m.masked("007"), m.masked("7"))
        XCTAssertEqual(m.masked("id=0001"), m.masked("id=42"))
    }

    // MARK: - 全角字符（该值将被移除，但与半角字符的任何差异将保留）

    func testFullWidthDigitsDifferFromAscii() {
        XCTAssertEqual(mask.masked("１２３"), mask.masked("４５６"))
        XCTAssertNotEqual(mask.masked("１２３"), mask.masked("123"))
        XCTAssertNotEqual(mask.masked("ＡＢＣ"), mask.masked("ABC"))
    }

    // MARK: - 日语（折叠为值，但保留全角符号作为“形状”）

    /// 如果日语 CSV 无法合并，则名称和地址都将发生变化。
    /// “忽略该值”的说法是错误的（我注意到实际公司编号为 CSV）。
    func testJapaneseTextIsAValueNotAFormat() {
        XCTAssertEqual(mask.masked("釧路検察審査会"), mask.masked("伊達簡易裁判所"))
        XCTAssertEqual(mask.masked("氏名,2026-08-19"), "T,9999-99-99")
        XCTAssertEqual(mask.masked("\"北海道\",\"釧路市\""), mask.masked("\"東京都\",\"港区\""))
    }

    /// 全角符号和全角空格不折叠 — `、` 和 `,`，全角空格和半角空格的区别
    /// **正是我要找的形状差异。**
    func testFullWidthPunctuationStaysAFormat() {
        XCTAssertNotEqual(mask.masked("東京、大阪"), mask.masked("東京,大阪"))
        XCTAssertNotEqual(mask.masked("氏名　太郎"), mask.masked("氏名 太郎"))
    }

    func testScriptDifferenceIsAFormatDifference() {
        XCTAssertNotEqual(mask.masked("山田"), mask.masked("Yamada"))
    }

    // MARK: - 选择如何粉碎它

    func testSpacesOption() {
        let m: FormatMask = [.digits, .letters, .spaces]
        XCTAssertEqual(m.masked("a  b"), m.masked("a b"))
        XCTAssertEqual(m.masked("a b   "), m.masked("a b"))
        // 默认情况下，尾随空格会被保留为差异。
        XCTAssertNotEqual(mask.masked("a b   "), mask.masked("a b"))
    }

    func testQuotesOption() {
        let m: FormatMask = [.digits, .letters, .quotes]
        XCTAssertEqual(m.masked("\"abc\",\"12\""), m.masked("abc,12"))
        XCTAssertNotEqual(mask.masked("\"abc\""), mask.masked("abc"))
    }

    func testLetterCaseOption() {
        let m: FormatMask = [.digits, .letterCase]
        XCTAssertEqual(m.masked("Error"), m.masked("ERROR"))
        XCTAssertNotEqual(m.masked("Error"), m.masked("Warn"))
    }

    func testEmptyMaskIsAPassThrough() {
        let m: FormatMask = []
        XCTAssertEqual(m.masked("2026-08-19 ERROR  "), "2026-08-19 ERROR  ")
    }

    // MARK: - 线段分割方法（如果与正常的 diff 不同，左右对应关系将会破坏）

    private func hashes(_ mask: FormatMask, _ text: String) -> [LineHash] {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { buf in
            mask.hashLines(UnsafeRawBufferPointer(buf))
        }
    }

    func testLineSplittingMatchesPlainHasher() {
        for text in ["a\nb\nc", "a\nb\n", "", "\n", "a\r\nb\r\n", "a\n\nb", "no newline at end"] {
            var bytes = Array(text.utf8)
            let plain = bytes.withUnsafeMutableBufferPointer { LineHasher.hashLines(UnsafeRawBufferPointer($0)) }
            XCTAssertEqual(hashes(.standard, text).count, plain.count, "行数が食い違う: \(text.debugDescription)")
        }
    }

    func testEmptyMaskHashesMatchPlainHasher() {
        let text = "2026-08-19 ERROR\r\nplain\n"
        var bytes = Array(text.utf8)
        let plain = bytes.withUnsafeMutableBufferPointer { LineHasher.hashLines(UnsafeRawBufferPointer($0)) }
        XCTAssertEqual(hashes([], text), plain)
    }

    func testCRLFIsNotADifference() {
        XCTAssertEqual(hashes(.standard, "2026-08-19\r\n"), hashes(.standard, "2026-08-19\n"))
    }

    // MARK: - diff（这是实际路线）

    func testDiffSeesNoDifferenceWhenOnlyValuesDiffer() {
        let left = TextDiffSource(text: "2026-08-19 12:00:00 ERROR disk full\n2026-08-19 12:00:01 INFO ok",
                                  displayName: "test")
        let right = TextDiffSource(text: "2001-01-02 03:04:05 WARN net down\n2001-01-02 03:04:06 INFO no",
                                   displayName: "prod")
        XCTAssertFalse(DiffModel(ops: LineDiff.compute(left.lineHashes(), right.lineHashes())).isIdentical)
        let model = DiffModel(ops: LineDiff.compute(left.lineHashes(mask: .standard),
                                                    right.lineHashes(mask: .standard)))
        XCTAssertTrue(model.isIdentical, "値しか違わないのに差分が出た")
    }

    func testDiffCatchesTheDateFormatDifference() {
        let left = TextDiffSource(text: "2026-08-19 12:00:00 ok\n2026-08-19 12:00:01 ok", displayName: "test")
        let right = TextDiffSource(text: "2026-08-19 12:00:00 ok\n2026/08/19 12:00:01 ok", displayName: "prod")
        let model = DiffModel(ops: LineDiff.compute(left.lineHashes(mask: .standard),
                                                    right.lineHashes(mask: .standard)))
        XCTAssertFalse(model.isIdentical)
        XCTAssertEqual(model.changedRowCount, 1)
    }
}
