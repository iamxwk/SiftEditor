import XCTest
import AppKit
@testable import SiftEditorCore

/// 匹配行之前和之后的 N 行（相当于 `grep -C`）在两个窗格中应具有相同的效果。
///
/// 我将使用  / `AppSettings.filterContextLines` (UserDefaults.standard)，
/// 每次测试恢复到原始值。
final class FilterContextPaneTests: XCTestCase {

    private var savedContext = 0

    override func setUp() {
        super.setUp()
        savedContext = AppSettings.filterContextLines
        AppSettings.filterContextLines = 0    // 该窗格读取 init 处的此值。
    }

    override func tearDown() {
        AppSettings.filterContextLines = savedContext
        super.tearDown()
    }

    // MARK: - 小文件 (EditableViewer)

    private func editable(_ text: String) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    private let log = "a0\na1\nERROR here\na3\na4\na5\na6\nERROR again\na8\n"

    /// 默认值 (0) 与之前相同，仅匹配行。
    func testEditableFilterWithoutContextShowsOnlyMatches() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "ERROR here\nERROR again\n")
    }

    /// ±1 将前一行和后一行合并在一起（聚类是分开的，所以它们不会混合）。
    func testEditableFilterWithContextShowsNeighbours() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testText, "a1\nERROR here\na3\na6\nERROR again\na8\n")
    }

    /// 即使其他窗格中的设置发生更改，此窗格也会通过与当前显示的值进行比较来更新。
    func testEditableRefreshesWhenRequestedContextMatchesGlobalSetting() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        AppSettings.filterContextLines = 1

        v.setFilterContextLines(1)

        XCTAssertEqual(v._testText, "a1\nERROR here\na3\na6\nERROR again\na8\n")
    }

    /// 将外部设置与 getter 同步后，原始显示值的更改将会反映出来。
    func testEditableSyncsExternalContextBeforeRestoringDisplayedValue() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setFilterContextLines(2)
        AppSettings.filterContextLines = 3

        XCTAssertEqual(v.filterContextLines, 3)
        v.setFilterContextLines(0)

        XCTAssertEqual(AppSettings.filterContextLines, 0)
        XCTAssertEqual(v.filterContextLines, 0)
        XCTAssertEqual(v._testText, "ERROR here\nERROR again\n")
    }

    /// 当外部设置更改时，筛选器显示将更新，而无需调用 getter。
    func testEditableUpdatesFilteredTextWhenGlobalContextChanges() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)

        AppSettings.filterContextLines = 1

        XCTAssertEqual(v.filterContextLines, 1)
        XCTAssertEqual(v._testText, "a1\nERROR here\na3\na6\nERROR again\na8\n")
    }

    /// 即使显示前面和后面的行，“匹配行”也只会包含匹配的行（这不会增加分析结果的数量）。
    func testEditableMatchLinesExcludeContext() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setFilterContextLines(2)
        XCTAssertEqual(v.filterMatchLines ?? [], [2, 7], "文脈行を一致に数えないこと")
    }

    /// 如果将其改回  / 0，它将恢复正常（拉伸它可以缩小）。
    func testEditableContextCanBeTurnedBackOff() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setFilterContextLines(3)
        v.setFilterContextLines(0)
        XCTAssertEqual(v._testText, "ERROR here\nERROR again\n")
    }

    /// 按时间段筛选（拖动时间分布）时，不要添加前面或后面的行。
    /// 如果包含所选范围之外的行，“所选时间段”将变得不准确。
    func testEditableExplicitLinesIgnoreContext() {
        let v = editable(log)
        v.setFilterContextLines(2)
        v.showOnlyLines([4])
        XCTAssertEqual(v._testText, "a4\n")
        XCTAssertEqual(v.filterMatchLines ?? [], [4])
    }

    /// 四舍五入到上限（如果设置为无限制，则会显示整个文本，使筛选变得毫无意义）。
    func testContextIsClamped() {
        let v = editable(log)
        v.setFilterContextLines(-5)
        XCTAssertEqual(v.filterContextLines, 0)
        v.setFilterContextLines(9999)
        XCTAssertEqual(v.filterContextLines, FilterContext.maxContext)
    }

    /// 记住此设置（您打开的下一个文件也将看起来相同）。
    func testContextPersists() {
        editable(log).setFilterContextLines(4)
        XCTAssertEqual(AppSettings.filterContextLines, 4)
        XCTAssertEqual(editable(log).filterContextLines, 4, "新しいペインも覚えている値で始まる")
    }

    // MARK: - 超大文件 (PieceTableViewer)
    //
    // `_testLoad` 没有内存中的原始值 = `fileBuffer`，因此 `refresh()` 为
    // 绘图过程未继续。需要检查的是**如何确定要排列的行** (`filterDisplayLines`) 和
    // “当前匹配”动作。请查看 .app 中的实际屏幕显示。

    private func big(_ text: String) -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    /// 400 行日志。每 10 行出现 `ERROR`（匹配行数为 10、20、... 390）。
    /// 日志较短时，筛选后的结果可以显示在一屏上，并且第一行始终为 0。
    /// 它向上取整，不允许进行正确的滚动验证。
    private func longLog() -> (text: String, matches: [Int]) {
        var lines: [String] = []
        var matches: [Int] = []
        for i in 0..<400 {
            if i > 0, i % 10 == 0 { lines.append("ERROR \(i)"); matches.append(i) }
            else { lines.append("line \(i)") }
        }
        return (lines.joined(separator: "\n") + "\n", matches)
    }

    func testBigFileFilterWithoutContextShowsOnlyMatches() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        XCTAssertEqual(v._testFilterDisplayLines, [2, 7])
    }

    func testBigFileFilterWithContextShowsNeighbours() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testFilterDisplayLines, [1, 2, 3, 6, 7, 8])
    }

    /// 即使其他窗格中的设置已更改，此窗格也会重新排列当前显示。
    func testBigFileRefreshesWhenRequestedContextMatchesGlobalSetting() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        AppSettings.filterContextLines = 1

        v.setFilterContextLines(1)

        XCTAssertEqual(v._testFilterDisplayLines, [1, 2, 3, 6, 7, 8])
    }

    /// 将外部设置与 getter 同步后，通过将显示值改回其原始状态来重新排列筛选行。
    func testBigFileSyncsExternalContextBeforeRestoringDisplayedValue() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        v.setFilterContextLines(2)
        AppSettings.filterContextLines = 3

        XCTAssertEqual(v.filterContextLines, 3)
        v.setFilterContextLines(0)

        XCTAssertEqual(AppSettings.filterContextLines, 0)
        XCTAssertEqual(v.filterContextLines, 0)
        XCTAssertEqual(v._testFilterDisplayLines, [2, 7])
    }

    /// 当外部设置更改时，筛选后的显示行会重新计算，而无需调用 getter。
    func testBigFileUpdatesFilterRowsWhenGlobalContextChanges() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)

        AppSettings.filterContextLines = 1

        XCTAssertEqual(v.filterContextLines, 1)
        XCTAssertEqual(v._testFilterDisplayLines, [1, 2, 3, 6, 7, 8])
    }

    /// 文件末尾未超出边界（未尝试超出最后一行）。
    func testBigFileContextClampsAtFileEnd() {
        let v = big(log)                       // 9 行（0…8）
        v._testSetSearch(terms: ["a8"], matchLines: [8])
        v.setFilterMode(true)
        v.setFilterContextLines(3)
        XCTAssertEqual(v._testFilterDisplayLines, [5, 6, 7, 8])
    }

    /// 这指的是筛选过程开始时的第一个匹配项（确定要突出显示的行）。
    func testBigFileEnteringFilterSelectsFirstMatch() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testCurrentMatchLine, 2)
    }

    /// “搜索下一个”跳过上下文行，直接进行下一个匹配。
    /// （如果逐行滚动，越往前滚动，找到下一个匹配项的可能性就越小）。
    func testBigFileFindNextSkipsContextLines() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testCurrentMatchLine, 10, "最初の一致")
        v.findNext()
        XCTAssertEqual(v._testCurrentMatchLine, 20, "次の一致行へ（間の文脈行では止まらない）")
        XCTAssertEqual(v._testFilterDisplayLines[v._testTopLine], 19,
                       "先頭は一致行そのものでなく前の行（出した「直前」を画面の上に隠さない）")
        v.findPrev()
        XCTAssertEqual(v._testCurrentMatchLine, 10, "前の一致行へ")
    }

    /// 最后一行结束后，它会回到开头（即使显示了前一行和后一行，它也可以完成一个完整的循环）。
    func testBigFileFindNextWrapsAround() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        v.setFilterContextLines(2)
        for _ in 0..<(matches.count - 1) { v.findNext() }
        XCTAssertEqual(v._testCurrentMatchLine, matches.last)
        v.findNext()
        XCTAssertEqual(v._testCurrentMatchLine, matches.first, "末尾の次は先頭")
    }

    /// 指定时间段时，不要添加前面或后面的行 (`showOnlyLines`)。
    func testBigFileExplicitLinesIgnoreContext() {
        let v = big(log)
        v.setFilterContextLines(2)
        v.showOnlyLines([4])
        XCTAssertEqual(v._testFilterDisplayLines, [4])
    }

    /// 即使您更改上一行或下一行，当前在顶部可见的行仍将保持在顶部（不会丢失）。
    func testBigFileKeepsTopLineWhenContextChanges() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        for _ in 0..<5 { v.findNext() }
        let top = v._testFilterDisplayLines[v._testTopLine]
        XCTAssertEqual(top, 60, "前提: 6 件目の一致を先頭に見ている")
        v.setFilterContextLines(2)
        XCTAssertEqual(v._testFilterDisplayLines[v._testTopLine], top, "同じ行が先頭に残る")
    }

    /// 如果移除过滤器，您刚才查看的行将成为主要文本。
    func testBigFileLeavingFilterKeepsThePlace() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        for _ in 0..<3 { v.findNext() }
        let top = v._testFilterDisplayLines[v._testTopLine]
        v.setFilterMode(false)
        XCTAssertEqual(v._testTopLine, top, "解除後は元の行番号で同じ場所")
    }
}
