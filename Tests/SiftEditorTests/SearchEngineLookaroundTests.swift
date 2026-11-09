import XCTest
@testable import SiftEditorCore

/// 回归测试，以验证正则表达式环视（前瞻和后瞻）在搜索引擎中是否有效。
/// 该引擎直接使用 `NSRegularExpression` (ICU)，因此这是为了检测 ICU 方面未来可能出现的退化而采取的措施。
final class SearchEngineLookaroundTests: XCTestCase {
    /// 将给定的文本写入文件，并返回与 regex 模式匹配的行号（从 0 开始）。
    private func matchingLines(_ content: String, pattern: String) -> [Int] {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("searchla-\(UUID().uuidString).log")
        try? content.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let buffer = FileBuffer(url: url) else { XCTFail("buffer"); return [] }
        let engine = SearchEngine(buffer: buffer, encoding: .utf8)
        let rx = try! NSRegularExpression(pattern: pattern)
        let done = expectation(description: "search")
        var lines: [Int] = []
        engine.search(.regex(rx), progress: { _, _ in }, completion: { res in
            lines = res.lines
            done.fulfill()
        })
        wait(for: [done], timeout: 5)
        return lines
    }

    func testPositiveLookahead() {
        let text = "foobar\nfoobaz\nfooqux\n"
        // 只匹配包含后面紧跟 "bar" 的 "foo" 的行。
        XCTAssertEqual(matchingLines(text, pattern: "foo(?=bar)"), [0])
    }

    func testNegativeLookahead() {
        let text = "error: disk\nerror: ok\nwarn: disk\n"
        // "error"，其中紧随其后的字符不是 "ok"。
        XCTAssertEqual(matchingLines(text, pattern: "error(?!: ok)"), [0])
    }

    func testPositiveLookbehind() {
        let text = "id=42\nno match here\nkey=99\n"
        // “”后面紧跟的数字是。
        XCTAssertEqual(matchingLines(text, pattern: "(?<==)\\d+"), [0, 2])
    }

    func testNegativeLookbehind() {
        let text = "x123\n 456\nabc\n"
        // 一个数字序列，其中前一个字符不是数字。
        XCTAssertEqual(matchingLines(text, pattern: "(?<!\\d)\\d+"), [0, 1])
    }

    func testVariableLengthLookbehind() {
        let text = "user@example.com\nname@other.org\n"
        // "@example" 前面的单词（匹配可变长度读取后）。
        XCTAssertEqual(matchingLines(text, pattern: "\\w+(?=@example)"), [0])
    }
}
