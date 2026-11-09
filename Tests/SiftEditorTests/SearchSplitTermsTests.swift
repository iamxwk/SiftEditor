import XCTest
@testable import SiftEditorCore

/// 搜索字段字符串 → 单词。仅输入空格（我想查找半角空格）结果为“零个单词”。
/// 修复了找不到任何结果的错误。
final class SearchSplitTermsTests: XCTestCase {

    func testSplitsOnWhitespace() {
        XCTAssertEqual(SearchMode.splitTerms("foo  bar\tbaz"), ["foo", "bar", "baz"])
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(SearchMode.splitTerms(""), [])
    }

    func testWhitespaceOnlyIsOneTerm() {
        XCTAssertEqual(SearchMode.splitTerms(" "), [" "])
        XCTAssertEqual(SearchMode.splitTerms("  "), ["  "])
    }

    func testSingleSpaceMatchesLineWithSpace() {
        let m = LineMatcher(mode: .terms(SearchMode.splitTerms(" ")), caseSensitive: false, encoding: .utf8)
        XCTAssertFalse(m.isEmpty)
        let hit = [UInt8]("a b".utf8), miss = [UInt8]("ab".utf8)
        XCTAssertTrue(hit.withUnsafeBufferPointer { m.matches($0) })
        XCTAssertFalse(miss.withUnsafeBufferPointer { m.matches($0) })
    }
}
