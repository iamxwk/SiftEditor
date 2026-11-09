import XCTest
@testable import SiftEditorCore

/// 计算并把握结构化显示的列宽。
///
/// **如果列边界处的数字未对齐，则抓取的位置和移动的列将不匹配。** 这是格式化后的结果（实际
/// 通过与  / 字符串进行比较来测量）——单独写出宽度加法，分隔符 ` │ ` 的 3 位数字
/// 我数到哪里就数不清了。
final class ColumnWidthDragTests: XCTestCase {

    private func csv(_ lines: [String]) -> TabularFormatter {
        TabularFormatter.build(mode: .csv, sampleLines: lines)
    }

    private let rows = ["name,age,city", "Alice,30,Tokyo", "Bob,7,Osaka"]

    // MARK: - 列的起始数字

    /// 格式化后的实际字符串必须与每一列内容的起始位置匹配。
    func testColumnStartsMatchFormattedText() {
        let f = csv(rows)
        let line = f.format(rows[1])                 // "Alice │ 30  │ Tokyo"
        let starts = f.columnStartColumns()
        XCTAssertEqual(starts.first, 1)
        for (j, cell) in f.cells(of: rows[1]).enumerated() where !cell.isEmpty {
            let start = starts[j] - 1                // 0 回到开头
            let chars = Array(line)
            let actual = String(chars[start..<min(chars.count, start + cell.count)])
            XCTAssertEqual(actual, cell, "\(j) 列目の始まりがズレている")
        }
    }

    /// 请确认没有遗漏任何分隔符（3 位数字）。
    func testColumnStartsIncludeSeparatorWidth() {
        let f = csv(rows)
        // name 该列有 5 位数字 (Alice) → 下一列从第 9 位数字开始 (1 + 5 + 3 = 第 9 位数字)。
        XCTAssertEqual(f.columnStartColumns(), [1, 9, 15])
        XCTAssertEqual(f.separatorColumn(after: 0), 6)
    }

    // MARK: - 更改宽度

    func testWithColumnWidthChangesOnlyThatColumn() {
        let f = csv(rows).withColumnWidth(0, 10)
        XCTAssertEqual(f.columns.map(\.width), [10, 3, 5])
        XCTAssertEqual(f.format(rows[1]), "Alice      │ 30  │ Tokyo")
    }

    func testWithColumnWidthIsClamped() {
        let f = csv(rows)
        XCTAssertEqual(f.withColumnWidth(0, 0).columns[0].width, TabularFormatter.minColumnWidth)
        XCTAssertEqual(f.withColumnWidth(0, 9999).columns[0].width, TabularFormatter.maxColumnWidth)
    }

    func testWithColumnWidthIgnoresUnknownColumn() {
        let f = csv(rows)
        XCTAssertEqual(f.withColumnWidth(99, 10).columns.map(\.width), f.columns.map(\.width))
    }

    /// 即使您更改宽度，其他列的内容也不会被截断（只有分隔符的位置会移动）。
    func testNarrowedColumnTruncatesWithEllipsis() {
        let f = csv(rows).withColumnWidth(0, 3)
        XCTAssertEqual(f.format(rows[1]), "Al… │ 30  │ Tokyo")
    }

    // MARK: - 抓取和移动

    func testDraggingSeparatorSetsWidth() {
        let f = csv(rows)
        // 将第一列的分隔符扩展到第 12 位数字 → 宽度为 12-1 = 11。
        XCTAssertEqual(f.width(forSeparatorOf: 0, draggedTo: 12), 11)
        // 对于 ，将第二列中的分隔符（从第 9 位数字开始）移动到第 20 位数字 → 11。
        XCTAssertEqual(f.width(forSeparatorOf: 1, draggedTo: 20), 11)
    }

    /// 即使你把所有的积木都推到左边，也要留一个数字（如果你把它设置为 0，抓取手就会消失，而且你将无法把它移回去）。
    func testDraggingPastLeftEdgeKeepsOneColumn() {
        let f = csv(rows)
        XCTAssertEqual(f.width(forSeparatorOf: 0, draggedTo: 1), TabularFormatter.minColumnWidth)
        XCTAssertEqual(f.width(forSeparatorOf: 0, draggedTo: -50), TabularFormatter.minColumnWidth)
    }

    /// 抓握手的位置应跟随宽度的变化（抓取→移动→再次抓取，依此类推）。
    func testSeparatorFollowsNewWidth() {
        let f = csv(rows).withColumnWidth(0, 11)
        XCTAssertEqual(f.separatorColumn(after: 0), 12)
        XCTAssertEqual(f.columnStartColumns()[1], 15)
    }

    /// 即使对于固定长度的数据，同样的计算也适用（列名就变成了数字本身）。
    func testWorksForFixedWidthToo() {
        let lines = ["00012345TOKYO 20260815"]
        let f = TabularFormatter.build(mode: .fixedWidth, sampleLines: lines,
                                       fields: ColumnGuides([9, 15]).fieldRanges(fitting: lines))
        XCTAssertEqual(f.columnStartColumns(), [1, 12, 20])
        XCTAssertEqual(f.withColumnWidth(0, 4).format(lines[0]), "000… │ TOKYO │ 20260815")
    }
}
