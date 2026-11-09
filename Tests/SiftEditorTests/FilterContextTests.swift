import XCTest
@testable import SiftEditorCore

/// 扩展 N 行（相当于 `grep -C`）在匹配行之前和之后的内容。
///
/// 筛选功能仅显示“该行”，但搜索过程需要来回切换。如果您看不到前后的内容……
/// 此功能的目的是让您能够移除筛选条件并按行号再次搜索。
final class FilterContextTests: XCTestCase {
    func testZeroContextReturnsMatchesUnchanged() {
        let m = [3, 10, 11]
        XCTAssertEqual(FilterContext.expand(matches: m, context: 0, lineCount: 100), m)
    }

    func testExpandsAroundEachMatch() {
        XCTAssertEqual(FilterContext.expand(matches: [5], context: 2, lineCount: 100),
                       [3, 4, 5, 6, 7])
    }

    /// 即使窗口重叠，也不要显示同一行两次（类似于 `grep` 合并后续行的方式）。
    func testOverlappingWindowsAreMerged() {
        XCTAssertEqual(FilterContext.expand(matches: [5, 7], context: 2, lineCount: 100),
                       [3, 4, 5, 6, 7, 8, 9])
    }

    /// 相邻的匹配元素构成一个块。
    func testAdjacentMatches() {
        XCTAssertEqual(FilterContext.expand(matches: [5, 6], context: 1, lineCount: 100),
                       [4, 5, 6, 7])
    }

    /// 如果它们相距很远，则簇将分离（中间的线条不显示 = 这就是它们缺失的地方）。
    func testDistantMatchesStayInSeparateGroups() {
        XCTAssertEqual(FilterContext.expand(matches: [2, 20], context: 1, lineCount: 100),
                       [1, 2, 3, 19, 20, 21])
    }

    /// 请勿超出文件边缘的边界。
    func testClampsToFileEnds() {
        XCTAssertEqual(FilterContext.expand(matches: [0], context: 3, lineCount: 3), [0, 1, 2])
        XCTAssertEqual(FilterContext.expand(matches: [9], context: 3, lineCount: 10), [6, 7, 8, 9])
    }

    func testEmptyInputs() {
        XCTAssertEqual(FilterContext.expand(matches: [], context: 5, lineCount: 100), [])
        XCTAssertEqual(FilterContext.expand(matches: [1], context: 5, lineCount: 0), [1],
                       "行数が分からないときは触らない（切り落とすより出さない方が安全）")
    }

    /// 即使匹配项完全隐藏在先前显示的窗口中，其顺序和无重复项也不会受到影响。
    func testResultIsSortedAndUnique() {
        let out = FilterContext.expand(matches: [4, 5, 6, 7, 30], context: 10, lineCount: 50)
        XCTAssertEqual(out, Array(0...17) + Array(20...40))
        XCTAssertEqual(out, out.sorted())
        XCTAssertEqual(out.count, Set(out).count)
    }

    /// 停止在上限处（如果简单地将 100 万个匹配项向前和向后扩展 100 行，则变为 1.6GB）。
    func testStopsAtDisplayCap() {
        let matches = Array(stride(from: 0, to: 4_000_000, by: 2))
        let out = FilterContext.expand(matches: matches, context: 1, lineCount: 4_000_000)
        XCTAssertEqual(out.count, FilterContext.displayCap)
        XCTAssertEqual(out.first, 0)
    }
}
