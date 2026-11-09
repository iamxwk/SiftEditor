import XCTest
import AppKit
@testable import SiftEditorCore

/// 结构化显示（列对齐）可与搜索、筛选和关注功能结合使用。
///
/// 最初，大文件端在结构化过程中丢失了 `supportsSearch` / `supportsFollow`。
/// 当这些数字对齐后，就无法搜索或追踪了（前来参观 CSV 的人最想做的就是……）
/// 通常情况下，它会被过滤掉，所以在我最想使用它的地方无法使用。
/// 搜索是关于字节定位的，而对齐是关于数据的显示方式的；它们是相互独立的，因此可以一起使用。
/// 但是，由于在保持格式化外观的同时重写它会导致所见与所见之间存在差异，因此排除了替换功能。
final class StructuredSearchTests: XCTestCase {
    private func makeViewer(_ text: String) -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    private let csv = "id,name,level\n1,alpha,error\n2,bravo,info\n3,charlie,error\n"

    // MARK: 即使在结构化数据中，搜索和跟踪仍然活跃。

    /// `_testLoad` 是一个内存中的原始文件，因此它没有 `searchEngine` / `fileBuffer`。
    /// 是否可以搜索和追踪仍取决于此处的 false。请查看……
    /// **结构的存在与否并不影响其是否可接受**（以前，它仅仅因为没有结构而被拒绝）。
    func testSearchAvailabilityIsUnaffectedByStructured() {
        let v = makeViewer(csv)
        let plain = v.supportsSearch
        v.setStructuredMode(.csv)
        XCTAssertEqual(v.supportsSearch, plain, "構造化を理由に検索を落とさないこと")
        v.setStructuredMode(nil)
        XCTAssertEqual(v.supportsSearch, plain)
    }

    func testFollowStaysAvailableWhileStructured() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        // 后续操作需要实际文件，因此它在 _testLoad（内存中）中仍为 false。
        // 我们需要确认的是“结构本身不是故障的原因”。
        v.setStructuredMode(nil)
        let plain = v.supportsFollow
        v.setStructuredMode(.csv)
        XCTAssertEqual(v.supportsFollow, plain, "構造化の有無で追従の可否が変わらないこと")
    }

    // MARK: 过滤器和结构化并非互斥的。

    func testFilterSurvivesTurningStructuredOn() {
        let v = makeViewer(csv)
        v._testSetSearch(terms: ["error"], matchLines: [1, 3])
        v.setFilterMode(true)
        XCTAssertTrue(v._testFilterMode)

        v.setStructuredMode(.csv)
        XCTAssertTrue(v._testFilterMode, "桁を揃えたまま grep する（構造化に入ってもフィルタを落とさない）")
    }

    func testFilterSurvivesTurningStructuredOff() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        v._testSetSearch(terms: ["error"], matchLines: [1, 3])
        v.setFilterMode(true)

        v.setStructuredMode(nil)
        XCTAssertTrue(v._testFilterMode, "構造化を解いてもフィルタは続く")
    }

    // MARK: 只会丢弃替换件。

    func testReplaceUnavailableWhileStructured() {
        let v = makeViewer(csv)
        XCTAssertTrue(v.supportsReplace)
        v.setStructuredMode(.csv)
        XCTAssertFalse(v.supportsReplace, "整形した見た目のまま書き換えさせない")
        v.setStructuredMode(nil)
        XCTAssertTrue(v.supportsReplace)
    }

    func testReplaceAllIsRefusedWhileStructured() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        v._testSetSearch(terms: ["error"], matchLines: [1, 3])
        v._testReplaceAll("ERROR")
        XCTAssertEqual(v._testDocString, csv, "構造化中の置換は本文を変えないこと")
    }

    func testReplaceCurrentIsRefusedWhileStructured() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        v._testSetSearch(terms: ["error"], matchLines: [1])
        v._testSelect(19..<24)
        v._testReplaceCurrent("ERROR")
        XCTAssertEqual(v._testDocString, csv, "構造化中の置換は本文を変えないこと")
    }

    // MARK: 筛选后，调整列宽以匹配筛选后的行。

    /// 一个文件中，长值仅出现在中间行。以前列宽是根据列的开头和结尾确定的。
    /// 通过  / `long` 筛选的结果已损坏为 `x…` 且无法读取（已于 2026 年 8 月 21 日在实际设备上确认）。
    /// 列宽由前 1000 行 + 后 1000 行决定，因此将其设置为**两端都无法容纳的行数**。
    private static let middleRow = 1500
    private func lopsided(_ middle: String) -> String {
        var lines = ["id,note"]
        for i in 1...3000 {
            lines.append(i == Self.middleRow ? "\(i),\(middle)" : "\(i),ok")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func testColumnWidthFollowsFilteredRows() {
        let middle = "connection reset by peer"      // 24 桁
        let v = makeViewer(lopsided(middle))
        v.setStructuredMode(.csv)
        let unfiltered = v._testStructuredColumnWidths
        XCTAssertLessThan(unfiltered[1], middle.count, "全体では 'ok' と見出しで決まる（前提）")

        // 筛选器，仅匹配中间行。
        v._testSetSearch(terms: [middle], matchLines: [Self.middleRow])
        v.setFilterMode(true)
        XCTAssertEqual(v._testStructuredColumnWidths[1], middle.count,
                       "絞り込んだ行が切れずに出ること（桁を揃えたまま grep する）")
    }

    func testColumnWidthReturnsToWholeFileWhenFilterIsCleared() {
        let middle = "connection reset by peer"
        let v = makeViewer(lopsided(middle))
        v.setStructuredMode(.csv)
        let unfiltered = v._testStructuredColumnWidths
        v._testSetSearch(terms: [middle], matchLines: [Self.middleRow])
        v.setFilterMode(true)
        v.setFilterMode(false)
        XCTAssertEqual(v._testStructuredColumnWidths, unfiltered,
                       "フィルタを解いたら元の桁に戻ること")
    }

    /// 即使没有匹配项，该列也不会消失或下移。
    func testEmptyFilterKeepsColumns() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        let before = v._testStructuredColumnWidths
        v._testSetSearch(terms: ["nothing"], matchLines: [])
        v.setFilterMode(true)
        XCTAssertTrue(v._testFilterMode)
        XCTAssertEqual(v._testStructuredColumnWidths, before, "0 件でも列名の帯を空にしないこと")
    }
}
