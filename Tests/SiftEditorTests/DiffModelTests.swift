import XCTest
@testable import SiftEditorCore

/// 并排查看时的行模型，以及复制选定范围。
final class DiffModelTests: XCTestCase {

    /// 左手 [a, b, c, d] → 右手 [a, X, c, d, e] 等效手。
    /// 表示行: 0=a(equal) 1=b↔X(replace) 2=c(equal) 3=d(equal) 4=e(insert)
    private func sampleModel() -> DiffModel {
        DiffModel(ops: [
            .equal(left: 0, right: 0, count: 1),
            .replace(left: 1, leftCount: 1, right: 1, rightCount: 1),
            .equal(left: 2, right: 2, count: 2),
            .insert(right: 4, count: 1),
        ])
    }

    func testRowMapping() {
        let m = sampleModel()
        XCTAssertEqual(m.rowCount, 5)

        XCTAssertEqual(m.row(at: 0)?.left, 0)
        XCTAssertEqual(m.row(at: 0)?.right, 0)

        XCTAssertEqual(m.row(at: 1)?.kind, .replace)
        XCTAssertEqual(m.row(at: 1)?.left, 1)
        XCTAssertEqual(m.row(at: 1)?.right, 1)

        XCTAssertEqual(m.row(at: 3)?.left, 3)

        // 是仅存在于右侧的行。左侧是填充行 (nil)。
        XCTAssertEqual(m.row(at: 4)?.kind, .insert)
        XCTAssertNil(m.row(at: 4)?.left)
        XCTAssertEqual(m.row(at: 4)?.right, 4)

        XCTAssertNil(m.row(at: 5))
    }

    /// 差异的开始（显示行）。
    func testHunkStarts() {
        let m = sampleModel()
        XCTAssertEqual(m.hunkStarts, [1, 4])
    }

    /// “下一个差异”根据**选定的汉克**进行。
    ///
    /// 最初，它是基于滚动位置（topRow）的，因此对于适合屏幕的小文件……
    /// topRow 的值始终为 0，而且**无论我按多少次，它都恢复到相同的差值**。我只在 GUI 上注意到这个问题。
    /// 这是一个漏洞，所以将在此处修复。
    func testHunkNavigationAdvancesFromCurrentHunk() {
        let m = sampleModel()
        let hunks = m.hunkOpIndices          // [1(replace), 3(insert)]
        XCTAssertEqual(hunks, [1, 3])

        // 如果您尚未选择任何内容，您将获得第一个汉克。
        XCTAssertEqual(m.hunk(after: nil), 1)
        // **继续** 从第一项到第二项（不要返回到同一位置）。
        XCTAssertEqual(m.hunk(after: 1), 3)
        // 结尾部分已完结。
        XCTAssertNil(m.hunk(after: 3))

        // 退货流程相同。
        XCTAssertEqual(m.hunk(before: 3), 1)
        XCTAssertNil(m.hunk(before: 1))
        XCTAssertEqual(m.hunk(before: nil), 3)
    }

    /// Hank 的第一个显示行（要移动到的行）。
    func testStartRowOfOp() {
        let m = sampleModel()
        XCTAssertEqual(m.startRow(ofOp: 0), 0)   // equal
        XCTAssertEqual(m.startRow(ofOp: 1), 1)   // replace
        XCTAssertEqual(m.startRow(ofOp: 2), 2)   // equal(2 行)
        XCTAssertEqual(m.startRow(ofOp: 3), 4)   // insert
    }

    func testChangedCounts() {
        let m = sampleModel()
        XCTAssertEqual(m.changedRowCount, 2)   // replace 1 行 ＋ insert 1 行
        XCTAssertFalse(m.isIdentical)
    }

    // MARK: - 副本

    /// 从左列复制。第 4 行仅存在于右侧 = 左侧为填充行，因此**请勿混入空白行**。
    func testCopySkipsFillerRows() {
        let m = sampleModel()
        let leftLines = ["a", "b", "c", "d"]
        let text = m.selectedText(from: (row: 2, idx: 0), to: (row: 4, idx: 0)) { row in
            m.row(at: row)?.left.map { leftLines[$0] }     // 如果不在左边，则为 nil
        }
        // ，仅第 2 行 (c) 和第 3 行 (d)。左侧不存在第 4 行，因此跳过它（不要将其写成“c\nd\n”）。
        XCTAssertEqual(text, "c\nd")
    }

    /// 从线段中间选择到中间（拖动选择）。
    func testCopyPartialRange() {
        let m = sampleModel()
        let lines = ["alpha", "bravo", "charlie", "delta"]
        let text = m.selectedText(from: (row: 0, idx: 2), to: (row: 2, idx: 4)) { row in
            m.row(at: row)?.left.map { lines[$0] }
        }
        XCTAssertEqual(text, "pha\nbravo\nchar")
    }

    /// 不要拆分日文字符（包括代理对）。
    func testCopyDoesNotSplitSurrogatePairs() {
        let m = DiffModel(ops: [.equal(left: 0, right: 0, count: 1)])
        let line = "あ👨‍👩‍👦い"
        let all = m.selectedText(from: (row: 0, idx: 0), to: (row: 0, idx: line.utf16.count)) { _ in line }
        XCTAssertEqual(all, line)
    }

    /// 即使选择为空或超出范围也不会崩溃。
    func testCopyDegenerateRanges() {
        let m = sampleModel()
        XCTAssertEqual(m.selectedText(from: (row: 1, idx: 0), to: (row: 0, idx: 0)) { _ in "x" }, "")
        XCTAssertEqual(m.selectedText(from: (row: 0, idx: 0), to: (row: 99, idx: 0)) { _ in "x" }, "")
    }

    /// 滚动条上的差异标记位于差异位置 (0...1)。
    func testMarkers() {
        let m = sampleModel()
        let markers = m.markers()
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].kind, .replace)
        XCTAssertEqual(markers[0].position, 1.0 / 5.0, accuracy: 0.001)
        XCTAssertEqual(markers[1].kind, .insert)
        XCTAssertEqual(markers[1].position, 4.0 / 5.0, accuracy: 0.001)
    }
}
