import XCTest
import AppKit
@testable import SiftEditorCore

/// 在小文件编辑窗格中搜索、替换和跳转到行的功能。
/// (EditableViewer 将处理小于 8MB 的数字，但最初 `supportsSearch` 将是 false)
/// ⌘F 仅发出哔哔声。这是为了阻止该回归而进行的测试。
final class EditableViewerSearchTests: XCTestCase {
    private func viewer(_ text: String) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    // MARK: 可搜索

    func testEditablePaneSupportsSearch() {
        XCTAssertTrue(viewer("abc").supportsSearch)
    }

    /// 启用结构化视图时，它显示为只读，因此不会显示搜索栏（与大文件相同）。
    func testSearchUnavailableWhileStructured() {
        let v = viewer("a,b\n1,2\n")
        v.setStructuredMode(.csv)
        XCTAssertFalse(v.supportsSearch)
        v.setStructuredMode(nil)
        XCTAssertTrue(v.supportsSearch)
    }

    /// 匹配行筛选器 (live grep) 也可以在编辑窗格中使用。
    /// 以前，它只适用于大文件，对于普通大小的文件，漏斗按钮始终是灰色的。
    func testEditablePaneHasFilter() {
        XCTAssertTrue(viewer("abc").supportsSearchFilter)
    }

    /// 启用结构化显示时，主要文本已被替换，因此不会被过滤。
    func testFilterUnavailableWhileStructured() {
        let v = viewer("a,b\n1,2\n")
        v.setStructuredMode(.csv)
        XCTAssertFalse(v.supportsSearchFilter)
        v.setStructuredMode(nil)
        XCTAssertTrue(v.supportsSearchFilter)
    }

    /// 筛选器 ON 将只显示文本中匹配的行，而 OFF 会将其恢复到原始状态。
    func testFilterShowsOnlyMatchingLinesAndRestores() {
        let v = viewer("alpha\nbravo\nalpha again\ncharlie\n")
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "alpha\nalpha again\n")

        v.setFilterMode(false)
        XCTAssertEqual(v._testText, "alpha\nbravo\nalpha again\ncharlie\n")
    }

    /// 当查询更改时，筛选条件也应随之更改 (live grep)。
    func testFilterFollowsQueryChanges() {
        let v = viewer("alpha\nbravo\ncharlie\n")
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "alpha\n")

        v.setSearchQuery("bravo")
        XCTAssertEqual(v._testText, "bravo\n")
    }

    /// **即使经过筛选，原始文本仍会被保存并显示行数。**
    /// 如果操作错误，最终会导致“保存筛选结果时，其他行会消失”。
    func testFilterKeepsWholeTextForSaving() {
        let whole = "alpha\nbravo\ncharlie\n"
        let v = viewer(whole)
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "alpha\n")          // 仅显示匹配的行。
        XCTAssertEqual(v.restorableText, whole)          // 整个逻辑文本保持不变。
    }

    /// 筛选激活时为只读（以防止意外编辑仅匹配的行）。
    func testFilterIsReadOnly() {
        let v = viewer("alpha\nbravo\n")
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertFalse(v.canEdit)
        v.setFilterMode(false)
        XCTAssertTrue(v.canEdit)
    }

    // MARK: 如何统计火柴数量

    func testLiteralSearchCountsMatchesCaseInsensitiveByDefault() {
        let v = viewer("timeout\nTIMEOUT\nTimeout\nother\n")
        v.setSearchQuery("timeout")
        XCTAssertEqual(v._testMatchCount, 3)

        v.setCaseSensitive(true)
        XCTAssertEqual(v._testMatchCount, 1)
    }

    func testEmptyQueryClearsMatches() {
        let v = viewer("aaa")
        v.setSearchQuery("a")
        XCTAssertEqual(v._testMatchCount, 3)
        v.setSearchQuery("")
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// 空格分隔的条目捕获每个单词的所有出现（按文本顺序排列）。
    func testMultipleTermsAreCollectedInDocumentOrder() {
        let v = viewer("alpha beta\n")
        v.setSearchQuery("beta alpha")
        XCTAssertEqual(v._testMatchCount, 2)
        v.findNext()
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 5))   // alpha 首先出现。
    }

    /// 在正则表达式中，^ 表示行的开头（整个文本不被视为单个字符串进行匹配）。
    func testRegexAnchorsMatchLines() {
        let v = viewer("foo\nbarfoo\nfoo\n")
        v.setRegexMode(true)
        v.setSearchQuery("^foo")
        XCTAssertEqual(v._testMatchCount, 2)
    }

    func testRegexLookaheadWorks() {
        let v = viewer("ERROR: a\nERROR: b\nINFO: c\n")
        v.setRegexMode(true)
        v.setSearchQuery("ERROR(?=: b)")
        XCTAssertEqual(v._testMatchCount, 1)
    }

    func testInvalidRegexIsReportedAndFindsNothing() {
        let v = viewer("abc")
        v.setRegexMode(true)
        v.setSearchQuery("[")
        XCTAssertTrue(v._testSearchInvalid)
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// 如果在编辑过程中文本发生更改，则匹配位置将被重新计数。
    func testMatchesRecomputedAfterTextChanges() {
        let v = viewer("hit\n")
        v.setSearchQuery("hit")
        XCTAssertEqual(v._testMatchCount, 1)
        v._testSetText("hit\nhit\nhit\n")
        XCTAssertEqual(v._testMatchCount, 3)
    }

    // MARK: 前进/后退

    func testFindNextAdvancesAndWrapsAround() {
        let v = viewer("x\nx\n")   // 匹配项：0 和 2
        v.setSearchQuery("x")
        XCTAssertEqual(v._testMatchCount, 2)

        v.findNext()
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 1))
        XCTAssertEqual(v._testCurrentMatch, 1)

        v.findNext()
        XCTAssertEqual(v._testSelection, NSRange(location: 2, length: 1))
        XCTAssertEqual(v._testCurrentMatch, 2)

        v.findNext()   // 在最后一个数字之后，它移到开头。
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 1))
        XCTAssertEqual(v._testCurrentMatch, 1)
    }

    func testFindPrevGoesBackwardAndWrapsAround() {
        let v = viewer("x\nx\n")
        v.setSearchQuery("x")

        v.findPrev()   // 插入符 0 前没有空格 = 循环到末尾。
        XCTAssertEqual(v._testSelection, NSRange(location: 2, length: 1))

        v.findPrev()
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 1))
    }

    // MARK: 置換

    func testReplaceCurrentReplacesSelectionThenMovesOn() {
        let v = viewer("cat cat")
        v.setSearchQuery("cat")
        v.findNext()                       // 选择第一个
        v.replaceCurrent(with: "dog")
        XCTAssertEqual(v._testText, "dog cat")
        XCTAssertEqual(v._testSelection, NSRange(location: 4, length: 3))   // 已选择以下匹配项。
    }

    /// 如果选定的项目不匹配，则不会替换，而是直接搜索下一个项目（即，您可以按住来前进）。
    func testReplaceCurrentWithoutMatchSelectionOnlyMoves() {
        let v = viewer("cat cat")
        v.setSearchQuery("cat")
        v.replaceCurrent(with: "dog")
        XCTAssertEqual(v._testText, "cat cat")
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 3))
    }

    func testReplaceAllReplacesEveryMatch() {
        let v = viewer("cat\ncat\ncat\n")
        v.setSearchQuery("cat")
        v.replaceAll(with: "dog")
        XCTAssertEqual(v._testText, "dog\ndog\ndog\n")
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// 全部替换 1 撤销以恢复到原始状态。
    func testReplaceAllIsSingleUndo() {
        let v = viewer("cat cat cat")
        v.setSearchQuery("cat")
        v.replaceAll(with: "dog")
        XCTAssertEqual(v._testText, "dog dog dog")
        v._testUndo()
        XCTAssertEqual(v._testText, "cat cat cat")
    }

    /// 正则表达式中的 $1 扩展用于替换。
    func testReplaceAllExpandsRegexGroups() {
        let v = viewer("key=value\nname=mr\n")
        v.setRegexMode(true)
        v.setSearchQuery("^(\\w+)=(\\w+)$")
        v.replaceAll(with: "$2:$1")
        XCTAssertEqual(v._testText, "value:key\nmr:name\n")
    }

    /// 如果启用了大小写保留，则匹配拼写的格式将移至替换字符串。
    func testReplaceAllPreservesCase() {
        let v = viewer("timeout TIMEOUT Timeout")
        v.setSearchQuery("timeout")
        v.setPreserveCase(true)
        v.replaceAll(with: "delay")
        XCTAssertEqual(v._testText, "delay DELAY Delay")
    }

    /// 只读格式化期间请勿替换（请勿损坏正文）。
    func testReplaceRefusedWhileStructured() {
        let v = viewer("a,b\n1,2\n")
        v.setSearchQuery("1")
        v.setStructuredMode(.csv)
        v.replaceAll(with: "9")
        v.setStructuredMode(nil)
        XCTAssertEqual(v._testText, "a,b\n1,2\n")
    }

    // MARK: 行跳转 (⌘L)

    func testGoToLineMovesCaretToLineHead() {
        let v = viewer("one\ntwo\nthree\n")
        v.goToLine(3)
        XCTAssertEqual(v._testSelection, NSRange(location: 8, length: 0))   // "one\ntwo\n"
    }

    /// 超过行数的规格将四舍五入到最后一行（这不会导致 beep 或崩溃）。
    func testGoToLineClampsBeyondEnd() {
        let v = viewer("one\ntwo\n")
        v.goToLine(999)
        XCTAssertEqual(v._testSelection.location, 8)
    }
}

// MARK: - 商品数量上限（请勿填写四舍五入后的数字）

extension EditableViewerSearchTests {

    /// 如果未达到限制，则不会显示“终止”标记 = 可以按原样表示编号。
    func testMatchCountIsNotFlaggedCappedWhenUnderLimit() {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText("hit hit hit")
        v.setSearchQuery("hit")
        XCTAssertEqual(v._testMatchCount, 3)
        XCTAssertFalse(v._testMatchesCapped)
    }

    /// 当搜索栏达到上限时进行标记（搜索栏将显示“N 或更多结果”）。
    /// 正文文字较大，因为它与上限匹配。由于设计为同步计数，这部分也需要手动测量。
    func testMatchCountFlagsCappedAtLimit() {
        let cap = EditableViewer._testMatchCap
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(String(repeating: "a", count: cap + 100))
        v.setSearchQuery("a")
        XCTAssertEqual(v._testMatchCount, cap)      // 取消而不计数
        XCTAssertTrue(v._testMatchesCapped)         // = 下限，而非总数
    }

    /// “终止”一词在两种语言中均有出现，但密钥名称并未按原样显示。
    func testCappedCountStringsExist() {
        for key in ["search.foundCapped", "search.countCapped"] {
            XCTAssertNotEqual(L(key), key, key)
            XCTAssertFalse(L(key).isEmpty, key)
        }
    }
}

// MARK: - 按行筛选（分析 = 从时间分布接收数据）

/// `showOnlyLines` 会选中一行，**无论搜索内容如何**。在时间分布中拖动时区时，
/// 用于在正文中仅保留该时间段内的行。
extension EditableViewerSearchTests {

    private func filtered(_ text: String, lines: [Int]) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v.showOnlyLines(lines)
        return v
    }

    func testShowOnlyLinesKeepsExactlyThoseLines() {
        let v = filtered("a\nb\nc\nd\n", lines: [1, 3])
        XCTAssertEqual(v.filterMatchLines ?? [], [1, 3])
    }

    /// 主文本中仅保留选定的行（**不执行搜索**，因此不会出现匹配高亮显示）。
    func testShowOnlyLinesReplacesTheVisibleText() {
        let v = filtered("a\nb\nc\n", lines: [2])
        XCTAssertEqual(v._testText, "c\n")
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// 空数组被删除（恢复为原始文本）。
    func testEmptyLinesClearsTheFilter() {
        let v = filtered("a\nb\nc\n", lines: [1])
        v.showOnlyLines([])
        XCTAssertNil(v.filterMatchLines)
    }

    // MARK: 在过滤过程中输入结构化数据（顺序错误的陷阱）

    /// 从过滤结果切换到 CSV 表格时，应恢复完整源数据再构建表格。
    func testStructuredFromFilteredShowsFormattedWholeFile() {
        let csv = "id,level,note\n1,INFO,ok\n2,ERROR,boom\n3,INFO,ok\n"
        let v = viewer(csv)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        XCTAssertNotNil(v.filterMatchLines, "前提: 絞り込めている")

        v.setStructuredMode(.csv)

        XCTAssertNil(v.filterMatchLines, "进入表格前应退出过滤模式")
        XCTAssertEqual(v.structuredMode, .csv)
        guard let grid = v.subviews.compactMap({ $0 as? CSVGridView }).first else {
            return XCTFail("CSV 表格未显示")
        }
        XCTAssertEqual(grid.document.rowCount, 3)
        XCTAssertEqual(grid.document.columnNames, ["id", "level", "note"])
        XCTAssertEqual((0..<3).map { grid.document.value(row: $0, column: 0) }, ["1", "2", "3"])
    }

    /// 折叠后，再进行非结构化处理，即可恢复为原始文本（不保留任何过滤痕迹）。
    func testTurningStructuredOffAfterFilterRestoresOriginal() {
        let csv = "id,level,note\n1,INFO,ok\n2,ERROR,boom\n3,INFO,ok\n"
        let v = viewer(csv)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setStructuredMode(.csv)
        v.setStructuredMode(nil)
        XCTAssertEqual(v._testText, csv)
    }
}
